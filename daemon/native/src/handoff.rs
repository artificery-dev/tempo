//! The plymouth -> frontend display hand-off.
//!
//! flutter-pi starts while plymouth still holds the DRM master, renders its
//! first frame, and cannot commit it. At that first frame its handoff plugin
//! connects to tempod and passes the DRM fd it has been holding since
//! startup. Becoming master on that fd needs CAP_SYS_ADMIN (the fd was
//! never master, so the kernel's "was master before" exemption does not
//! apply), which is why it happens here and not in the unprivileged
//! frontend. The sequence is the one proven on the device by the original
//! in-engine plugin, plus the gating that keeps it from blanking the panel:
//!
//! 1. Check the fd really is a DRM primary node (char device, major 226, minor
//!    < 64) before touching it.
//! 2. Record which framebuffer each CRTC is scanning out right now, through
//!    that fd (GETRESOURCES/GETCRTC are unrestricted ioctls).
//! 3. If plymouth is running (`/run/plymouth/pid` exists): `plymouth update
//!    --status=tempo-handoff`, so the theme fades its throbber down to the bare
//!    logo, and wait 600 ms for that fade (a touch past the theme's 0.5 s).
//! 4. `plymouth deactivate`, under a 3 s timeout: it blocks until plymouth has
//!    dropped the master, and keeps its last frame on the panel (`quit` would
//!    free the buffer and leave garbage on mtk-drm).
//! 5. `DRM_IOCTL_SET_MASTER` on the fd, retried on EBUSY every 50 ms for up to
//!    2 s (plymouth's drop and our set can race). Any other errno fails at
//!    once: EACCES means we lost CAP_SYS_ADMIN, EINVAL/ENOTTY a bad fd.
//! 6. Reply `{"ok":true}`.
//! 7. After the reply, in the background: wait until some CRTC's framebuffer
//!    differs from what was recorded in step 2 - the frontend's first commit is
//!    on the panel - then close our copy of the fd and retire plymouth with
//!    `plymouth quit --retain-splash` until plymouthd is gone. Quitting before
//!    that first commit would blank the panel (plymouth's rmfb disables the
//!    plane). If nothing changes within 10 s, quit anyway and say so.
//!
//! Master is a property of the open file description, which the frontend
//! and we share; closing our duplicate afterwards changes nothing for the
//! frontend. Holding it would: a crashed frontend's master would live on in
//! our copy and its restart would get EBUSY. Hence step 7 closes it and
//! nothing caches it. The op is idempotent (SET_MASTER on the current master
//! returns 0), so a restarted frontend may ask again.
//!
//! plymouth being absent only costs log lines: the master step runs
//! regardless.

use std::{
    ffi::CStr,
    io,
    os::fd::{AsRawFd, BorrowedFd, OwnedFd, RawFd},
    path::Path,
    process::{Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};

/// `_IO('d', 0x1e)`: no argument, so the number is the same everywhere.
pub const DRM_IOCTL_SET_MASTER: u32 = 0x641e;
/// `DRM_IOWR(0xa0, struct drm_mode_card_res)`.
pub const DRM_IOCTL_MODE_GETRESOURCES: u32 = drm_iowr(0xa0, std::mem::size_of::<DrmModeCardRes>());
/// `DRM_IOWR(0xa1, struct drm_mode_crtc)`.
pub const DRM_IOCTL_MODE_GETCRTC: u32 = drm_iowr(0xa1, std::mem::size_of::<DrmModeCrtc>());
/// DRM's character-device major; minors 0..63 are primary (card) nodes,
/// 64..127 control, 128.. render nodes.
pub const DRM_MAJOR: u32 = 226;

/// The plymouth status string the tempo theme reacts to by fading out.
pub const PLYMOUTH_HANDOFF_STATUS: &str = "tempo-handoff";
const PLYMOUTH_PID_FILE: &str = "/run/plymouth/pid";

const FADE: Duration = Duration::from_millis(600);
const DEACTIVATE_TIMEOUT: Duration = Duration::from_secs(3);
const SET_MASTER_BACKOFF: Duration = Duration::from_millis(50);
const SET_MASTER_BUDGET: Duration = Duration::from_secs(2);
const COMMIT_POLL: Duration = Duration::from_millis(50);
const COMMIT_TIMEOUT: Duration = Duration::from_secs(10);
const RETIRE_ATTEMPTS: u32 = 20;
const RETIRE_BACKOFF: Duration = Duration::from_millis(300);

/// `_IOC(_IOC_READ|_IOC_WRITE, 'd', nr, size)` as ARM and x86 encode it.
const fn drm_iowr(nr: u32, size: usize) -> u32 {
    (3 << 30) | ((size as u32) << 16) | (0x64 << 8) | nr
}

/// What [`perform`] hands to [`finish`]: the scanout state before plymouth
/// let go, so the frontend's first commit can be recognized.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Recorded {
    /// (crtc id, fb id) per CRTC. Empty if it could not be read.
    pub crtcs: Vec<(u32, u32)>,
}

/// Steps 1-5: validate, record, fade, deactivate, take master. `Err` is the
/// text for the reply. On success the caller replies and then hands the fd
/// to [`finish`].
pub fn perform(fd: BorrowedFd<'_>) -> Result<Recorded, String> {
    let raw = fd.as_raw_fd();
    log!("handoff", "request received on fd {raw}");

    validate_drm_primary(raw)?;

    let recorded = match read_crtcs(raw) {
        Ok(crtcs) => {
            log!("handoff", "scanout before hand-off: {}", describe(&crtcs));
            Recorded { crtcs }
        }
        Err(e) => {
            log!(
                "handoff",
                "cannot read CRTC state ({}); retire will rely on the timer",
                strerror(&e)
            );
            Recorded::default()
        }
    };

    if Path::new(PLYMOUTH_PID_FILE).exists() {
        log!("handoff", "plymouth is up; fading the splash");
        plymouth(
            &["update", &format!("--status={PLYMOUTH_HANDOFF_STATUS}")],
            None,
        );
        thread::sleep(FADE);
    } else {
        log!(
            "handoff",
            "{PLYMOUTH_PID_FILE} absent: no splash to fade, skipping update"
        );
    }

    log!(
        "handoff",
        "deactivating plymouth (its last frame stays on the panel)"
    );
    plymouth(&["deactivate"], Some(DEACTIVATE_TIMEOUT));

    log!("handoff", "taking DRM master");
    match set_master(raw) {
        Ok(attempts) => {
            log!("handoff", "set-master ok (attempt {attempts})");
            Ok(recorded)
        }
        Err(e) => {
            let text = strerror(&e);
            let hint = match e.raw_os_error() {
                Some(libc::EACCES) => {
                    " - tempod lacks CAP_SYS_ADMIN; the unit must run as full root"
                }
                Some(libc::EINVAL) | Some(libc::ENOTTY) => " - not a usable DRM fd",
                Some(libc::EBUSY) => " - plymouth never let go of the master",
                _ => "",
            };
            log!("handoff", "set-master failed: {text}{hint}");
            Err(format!("DRM_IOCTL_SET_MASTER: {text}"))
        }
    }
}

/// Step 7, to run on its own thread after the reply has gone out. Takes the
/// fd so it is closed here, at the right moment, and nowhere else.
pub fn finish(fd: OwnedFd, recorded: Recorded) {
    let raw = fd.as_raw_fd();
    if recorded.crtcs.is_empty() {
        log!(
            "handoff",
            "no recorded scanout; waiting {}s before retiring plymouth",
            COMMIT_TIMEOUT.as_secs()
        );
        thread::sleep(COMMIT_TIMEOUT);
    } else {
        match wait_for_commit(raw, &recorded, COMMIT_TIMEOUT) {
            Some(now) => log!("handoff", "first commit seen: {}", describe(&now)),
            None => log!(
                "handoff",
                "WARNING: no commit seen within {}s; retiring plymouth anyway",
                COMMIT_TIMEOUT.as_secs()
            ),
        }
    }
    drop(fd);
    log!(
        "handoff",
        "closed our copy of fd {raw}; master stays with the frontend"
    );
    retire_plymouth();
}

/// The fd must be a DRM primary node: a character device with the DRM
/// major and a card minor. Render nodes cannot be master, and anything
/// else is not what the frontend meant to send.
pub fn validate_drm_primary(fd: RawFd) -> Result<(), String> {
    // SAFETY: fstat into a zeroed stat buffer; fd validity is what is tested.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut st) } != 0 {
        let e = io::Error::last_os_error();
        log!("handoff", "rejecting fd {fd}: fstat: {}", strerror(&e));
        return Err(format!("not a DRM primary node (fstat: {})", strerror(&e)));
    }
    let is_char = st.st_mode & libc::S_IFMT == libc::S_IFCHR;
    if is_drm_primary(is_char, st.st_rdev) {
        Ok(())
    } else {
        log!(
            "handoff",
            "rejecting fd {fd}: {} {}:{}",
            if is_char {
                "char device"
            } else {
                "not a char device,"
            },
            libc::major(st.st_rdev),
            libc::minor(st.st_rdev)
        );
        Err("not a DRM primary node".to_string())
    }
}

/// The primary-node test, on the raw facts.
pub fn is_drm_primary(is_char_device: bool, rdev: libc::dev_t) -> bool {
    is_char_device && libc::major(rdev) == DRM_MAJOR && libc::minor(rdev) < 64
}

/// `DRM_IOCTL_SET_MASTER` on `fd`, retried on EBUSY (plymouth has not let
/// go yet) every 50 ms for up to 2 s. Returns the attempt that succeeded;
/// any other errno fails immediately.
pub fn set_master(fd: RawFd) -> io::Result<u32> {
    let started = Instant::now();
    let mut attempt = 0;
    loop {
        attempt += 1;
        // SAFETY: SET_MASTER takes no argument; a non-DRM fd fails with ENOTTY.
        if unsafe { libc::ioctl(fd, DRM_IOCTL_SET_MASTER as _) } == 0 {
            return Ok(attempt);
        }
        let e = io::Error::last_os_error();
        match e.raw_os_error() {
            Some(libc::EBUSY) | Some(libc::EAGAIN) | Some(libc::EINTR)
                if started.elapsed() < SET_MASTER_BUDGET =>
            {
                log!(
                    "handoff",
                    "set-master attempt {attempt}: {}; retrying",
                    strerror(&e)
                );
                thread::sleep(SET_MASTER_BACKOFF);
            }
            _ => return Err(e),
        }
    }
}

/// Poll the CRTCs through `fd` until one scans out a different framebuffer
/// from `recorded`. Returns the state seen, or None on timeout.
pub fn wait_for_commit(
    fd: RawFd,
    recorded: &Recorded,
    timeout: Duration,
) -> Option<Vec<(u32, u32)>> {
    let started = Instant::now();
    loop {
        match read_crtcs(fd) {
            Ok(now) if scanout_changed(&recorded.crtcs, &now) => return Some(now),
            Ok(_) => {}
            Err(e) => log!(
                "handoff",
                "reading CRTC state: {} (still waiting)",
                strerror(&e)
            ),
        }
        if started.elapsed() >= timeout {
            return None;
        }
        thread::sleep(COMMIT_POLL);
    }
}

/// Has any CRTC's framebuffer changed from `before` (or a CRTC appeared)?
pub fn scanout_changed(before: &[(u32, u32)], now: &[(u32, u32)]) -> bool {
    now.iter()
        .any(|(crtc, fb)| match before.iter().find(|(c, _)| c == crtc) {
            Some((_, was)) => was != fb,
            None => true,
        })
}

/// Ask plymouth to quit until plymouthd is gone: a single quit can race the
/// frontend's master grab, so keep asking.
pub fn retire_plymouth() {
    for attempt in 1..=RETIRE_ATTEMPTS {
        if !process_running("plymouthd") {
            log!(
                "handoff",
                "quit: plymouthd is gone (after {} request(s))",
                attempt - 1
            );
            return;
        }
        plymouth(&["quit", "--retain-splash"], None);
        thread::sleep(RETIRE_BACKOFF);
    }
    log!(
        "handoff",
        "WARNING: plymouthd still running after {RETIRE_ATTEMPTS} quit requests"
    );
}

// --- DRM mode ioctls ------------------------------------------------------
// Only what the commit gate needs: which fb each CRTC shows. Layouts follow
// include/uapi/drm/drm_mode.h; both structs start with a __u64 and are
// 8-aligned on armhf and x86-64 alike.

#[repr(C)]
#[derive(Default)]
struct DrmModeCardRes {
    fb_id_ptr: u64,
    crtc_id_ptr: u64,
    connector_id_ptr: u64,
    encoder_id_ptr: u64,
    count_fbs: u32,
    count_crtcs: u32,
    count_connectors: u32,
    count_encoders: u32,
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
}

#[repr(C)]
struct DrmModeModeinfo {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type_: u32,
    name: [u8; 32],
}

#[repr(C)]
struct DrmModeCrtc {
    set_connectors_ptr: u64,
    count_connectors: u32,
    crtc_id: u32,
    fb_id: u32,
    x: u32,
    y: u32,
    gamma_size: u32,
    mode_valid: u32,
    mode: DrmModeModeinfo,
}

fn ioctl_retry(fd: RawFd, request: u32, arg: *mut libc::c_void) -> io::Result<()> {
    loop {
        // SAFETY: callers pass a pointer to the struct `request` expects.
        if unsafe { libc::ioctl(fd, request as _, arg) } == 0 {
            return Ok(());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

/// (crtc id, fb id) for every CRTC the device exposes, through `fd`.
pub fn read_crtcs(fd: RawFd) -> io::Result<Vec<(u32, u32)>> {
    // GETRESOURCES is a two-step: ask for the counts, then for the ids. The
    // counts can change in between (hotplug); go round again if they do.
    let mut ids: Vec<u32> = Vec::new();
    loop {
        let mut res = DrmModeCardRes::default();
        ioctl_retry(
            fd,
            DRM_IOCTL_MODE_GETRESOURCES,
            (&mut res as *mut DrmModeCardRes).cast(),
        )?;
        let count = res.count_crtcs as usize;
        if count == 0 {
            break;
        }
        ids.clear();
        ids.resize(count, 0);
        let mut res = DrmModeCardRes {
            crtc_id_ptr: ids.as_mut_ptr() as usize as u64,
            count_crtcs: res.count_crtcs,
            ..Default::default()
        };
        ioctl_retry(
            fd,
            DRM_IOCTL_MODE_GETRESOURCES,
            (&mut res as *mut DrmModeCardRes).cast(),
        )?;
        if res.count_crtcs as usize <= count {
            ids.truncate(res.count_crtcs as usize);
            break;
        }
    }

    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        // SAFETY: zeroed is a valid DrmModeCrtc (integers and a byte array).
        let mut crtc: DrmModeCrtc = unsafe { std::mem::zeroed() };
        crtc.crtc_id = id;
        ioctl_retry(
            fd,
            DRM_IOCTL_MODE_GETCRTC,
            (&mut crtc as *mut DrmModeCrtc).cast(),
        )?;
        out.push((crtc.crtc_id, crtc.fb_id));
    }
    Ok(out)
}

fn describe(crtcs: &[(u32, u32)]) -> String {
    if crtcs.is_empty() {
        return "no CRTCs".to_string();
    }
    crtcs
        .iter()
        .map(|(c, fb)| format!("crtc {c} -> fb {fb}"))
        .collect::<Vec<_>>()
        .join(", ")
}

// --- plymouth -------------------------------------------------------------

/// Run a `plymouth` client command, optionally killing it after `timeout`.
/// Failure - plymouth not installed, not running, refusing, or hanging - is
/// logged and otherwise ignored: the hand-off proceeds to the master step
/// regardless.
fn plymouth(args: &[&str], timeout: Option<Duration>) {
    let shown = format!("plymouth {}", args.join(" "));
    match run_with_timeout("plymouth", args, timeout) {
        Outcome::Success => log!("handoff", "{shown}: ok"),
        Outcome::Failed(status) => log!("handoff", "{shown}: {status} (ignored)"),
        Outcome::TimedOut => log!(
            "handoff",
            "{shown}: killed after {:?} (ignored)",
            timeout.unwrap()
        ),
        Outcome::NotRun(e) => log!("handoff", "{shown}: cannot run: {e} (ignored)"),
    }
}

#[derive(Debug)]
pub enum Outcome {
    Success,
    Failed(ExitStatus),
    TimedOut,
    NotRun(io::Error),
}

/// Run a command with stdin/stdout closed and stderr to ours; with a
/// timeout, kill it when that passes.
pub fn run_with_timeout(program: &str, args: &[&str], timeout: Option<Duration>) -> Outcome {
    let mut child = match Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(child) => child,
        Err(e) => return Outcome::NotRun(e),
    };
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Outcome::Success,
            Ok(Some(status)) => return Outcome::Failed(status),
            Ok(None) => {}
            Err(e) => return Outcome::NotRun(e),
        }
        if timeout.is_some_and(|t| started.elapsed() >= t) {
            let _ = child.kill();
            let _ = child.wait();
            return Outcome::TimedOut;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

/// `pidof <comm>` without the exec: is any process's `/proc/<pid>/comm`
/// equal to `comm`?
pub fn process_running(comm: &str) -> bool {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return false;
    };
    entries
        .filter_map(Result::ok)
        .filter(|e| {
            e.file_name()
                .to_str()
                .is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit()))
        })
        .any(|e| {
            std::fs::read_to_string(e.path().join("comm"))
                .map(|s| s.trim_end() == comm)
                .unwrap_or(false)
        })
}

/// The C library's text for an OS error, without Rust's `(os error N)`.
pub fn strerror(e: &io::Error) -> String {
    match e.raw_os_error() {
        // SAFETY: strerror returns a pointer to a static NUL-terminated string.
        Some(errno) => unsafe { CStr::from_ptr(libc::strerror(errno)) }
            .to_string_lossy()
            .into_owned(),
        None => e.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::{fs::File, os::fd::AsFd};

    use super::*;

    fn dev_null() -> File {
        File::open("/dev/null").unwrap()
    }

    #[test]
    fn ioctl_numbers_match_the_kernel_headers() {
        assert_eq!(DRM_IOCTL_SET_MASTER, 0x641e);
        assert_eq!(std::mem::size_of::<DrmModeCardRes>(), 64);
        assert_eq!(std::mem::size_of::<DrmModeModeinfo>(), 68);
        assert_eq!(std::mem::size_of::<DrmModeCrtc>(), 104);
        assert_eq!(DRM_IOCTL_MODE_GETRESOURCES, 0xc040_64a0);
        assert_eq!(DRM_IOCTL_MODE_GETCRTC, 0xc068_64a1);
    }

    #[test]
    fn primary_node_test() {
        assert!(is_drm_primary(true, libc::makedev(DRM_MAJOR, 0)));
        assert!(is_drm_primary(true, libc::makedev(DRM_MAJOR, 1)));
        assert!(
            !is_drm_primary(true, libc::makedev(DRM_MAJOR, 64)),
            "control node"
        );
        assert!(
            !is_drm_primary(true, libc::makedev(DRM_MAJOR, 128)),
            "render node"
        );
        assert!(!is_drm_primary(true, libc::makedev(1, 3)), "/dev/null");
        assert!(
            !is_drm_primary(false, libc::makedev(DRM_MAJOR, 0)),
            "not a char device"
        );
    }

    #[test]
    fn validation_rejects_non_drm_fds() {
        let null = dev_null();
        assert_eq!(
            validate_drm_primary(null.as_raw_fd()),
            Err("not a DRM primary node".into())
        );
        let dir = File::open("/").unwrap();
        assert_eq!(
            validate_drm_primary(dir.as_raw_fd()),
            Err("not a DRM primary node".into())
        );
        assert!(
            validate_drm_primary(-1)
                .unwrap_err()
                .starts_with("not a DRM primary node")
        );
    }

    #[test]
    fn validation_accepts_a_real_card_when_the_host_has_one() {
        // Only meaningful on a host where a card node can be opened (video
        // group); a no-op elsewhere.
        for n in 0..4 {
            if let Ok(card) = File::open(format!("/dev/dri/card{n}")) {
                assert_eq!(validate_drm_primary(card.as_raw_fd()), Ok(()));
                let crtcs = read_crtcs(card.as_raw_fd()).expect("GETRESOURCES/GETCRTC");
                assert!(!crtcs.is_empty());
            }
        }
    }

    #[test]
    fn set_master_on_a_non_drm_fd_fails_fast() {
        // ENOTTY is not "plymouth still holds it": no retries.
        let null = dev_null();
        let started = Instant::now();
        let err = set_master(null.as_fd().as_raw_fd()).unwrap_err();
        assert_eq!(err.raw_os_error(), Some(libc::ENOTTY));
        assert!(started.elapsed() < Duration::from_millis(500));
        assert_eq!(
            set_master(-1).unwrap_err().raw_os_error(),
            Some(libc::EBADF)
        );
    }

    #[test]
    fn crtc_read_on_a_non_drm_fd_is_enotty() {
        let null = dev_null();
        assert_eq!(
            read_crtcs(null.as_raw_fd()).unwrap_err().raw_os_error(),
            Some(libc::ENOTTY)
        );
    }

    #[test]
    fn scanout_change_detection() {
        let before = [(40, 70), (41, 0)];
        assert!(!scanout_changed(&before, &before));
        assert!(scanout_changed(&before, &[(40, 71), (41, 0)]), "new fb");
        assert!(
            scanout_changed(&before, &[(40, 0), (41, 0)]),
            "plane off counts too"
        );
        assert!(
            scanout_changed(&before, &[(40, 70), (41, 0), (42, 5)]),
            "new crtc"
        );
        assert!(
            !scanout_changed(&before, &[]),
            "nothing readable is not a change"
        );
    }

    #[test]
    fn commit_wait_times_out_without_a_drm_fd() {
        let null = dev_null();
        let recorded = Recorded {
            crtcs: vec![(1, 2)],
        };
        let started = Instant::now();
        assert!(wait_for_commit(null.as_raw_fd(), &recorded, Duration::from_millis(120)).is_none());
        assert!(started.elapsed() >= Duration::from_millis(120));
    }

    #[test]
    fn child_timeout() {
        assert!(matches!(
            run_with_timeout("true", &[], None),
            Outcome::Success
        ));
        assert!(matches!(
            run_with_timeout("false", &[], None),
            Outcome::Failed(_)
        ));
        assert!(matches!(
            run_with_timeout("/nonexistent/tempod-test", &[], None),
            Outcome::NotRun(_)
        ));
        let started = Instant::now();
        let out = run_with_timeout("sleep", &["5"], Some(Duration::from_millis(100)));
        assert!(matches!(out, Outcome::TimedOut), "{out:?}");
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn strerror_is_the_bare_text() {
        let text = strerror(&io::Error::from_raw_os_error(libc::EBUSY));
        assert!(text.to_lowercase().contains("busy"), "{text}");
        assert!(!text.contains("os error"));
    }

    #[test]
    fn process_running_sees_ourselves() {
        let me = std::fs::read_to_string("/proc/self/comm").unwrap();
        assert!(process_running(me.trim_end()));
        assert!(!process_running("no-such-process-tempod-test"));
    }
}
