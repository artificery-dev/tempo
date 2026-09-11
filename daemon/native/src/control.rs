//! The control socket: listen (systemd's socket or our own), and serve one
//! request per connection on its own thread.

use std::{
    fs,
    io::{self, Write},
    mem::{size_of, zeroed},
    os::{
        fd::{AsFd, AsRawFd, OwnedFd},
        unix::{
            fs::{FileTypeExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    process::ExitCode,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use serde_json::{Map, json};

use crate::{
    activation, fdpass, first_run, handoff, haptic,
    metrics::{Sample, Sysfs},
    output,
    protocol::{self, MAX_REQUEST_LEN, Op},
    radio, screen, settings, sound, timezone, volume,
};

/// A client that connects and then says nothing gets this long.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// What the request handlers share.
pub struct State {
    /// The most recent reading - the sampler's, or a `battery` op's own.
    pub latest: Arc<Mutex<Option<Sample>>>,
    /// Where to read a sample from when there is none yet.
    pub sysfs: Sysfs,
    /// Hand-offs are serialized: two at once would race each other's
    /// plymouth steps.
    handoff: Mutex<()>,
    /// The backlight.
    pub screen: screen::Screen,
    /// The sound server's default sink.
    pub volume: volume::Volume,
    /// The vibration motor.
    pub haptic: haptic::Haptic,
    /// The tick, the click and the thump.
    pub sound: sound::Sound,
    pub routing: output::Routing,
    /// The MT6627 receiver and its direct AFE audio route.
    pub radio: radio::Radio,
}

impl State {
    pub fn new(sysfs: Sysfs) -> State {
        State {
            latest: Arc::new(Mutex::new(None)),
            sysfs,
            handoff: Mutex::new(()),
            screen: screen::Screen::new(),
            volume: volume::Volume::new(volume::Volume::runtime_dir()),
            haptic: haptic::Haptic::new(PathBuf::from("/sys/class/input")),
            sound: sound::Sound::new(),
            routing: output::Routing::default(),
            radio: radio::Radio::new(),
        }
    }
}

/// The listener: systemd's if it passed one, else bound at `path`.
pub fn listener(path: &Path) -> io::Result<UnixListener> {
    if let Some(l) = activation::take_listener() {
        log!(
            "control",
            "serving the socket passed by systemd (fd {})",
            l.as_raw_fd()
        );
        return Ok(l);
    }
    bind(path)
}

/// Bind our own listener at `path`: parent directory created, a stale
/// socket file from an unclean exit removed, mode 0660.
pub fn bind(path: &Path) -> io::Result<UnixListener> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        fs::create_dir_all(dir)?;
    }
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_socket() => fs::remove_file(path)?,
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("{} exists and is not a socket", path.display()),
            ));
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o660))?;
    log!("control", "listening on {} (mode 0660)", path.display());
    Ok(listener)
}

/// Accept forever. Each connection gets a thread; the handlers are short
/// except the hand-off, which must not hold up a `ping`.
pub fn serve(listener: UnixListener, state: Arc<State>) -> ExitCode {
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                let state = Arc::clone(&state);
                let spawned = thread::Builder::new()
                    .name("control".into())
                    .spawn(move || handle(stream, &state));
                if let Err(e) = spawned {
                    log!("control", "cannot spawn a handler thread: {e}");
                }
            }
            Err(e) => {
                log!("control", "accept: {e}");
                thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

/// What to do once the reply is on the wire.
enum After {
    Nothing,
    /// A failed hand-off: close the fd, now that the reply is out.
    CloseFd(OwnedFd),
    /// Gate on the frontend's first commit, close the fd, retire plymouth.
    FinishHandoff(OwnedFd, handoff::Recorded),
}

pub(crate) fn handle(mut stream: UnixStream, state: &State) {
    let _ = stream.set_read_timeout(Some(REQUEST_TIMEOUT));
    let received = match fdpass::recv_line(&stream, MAX_REQUEST_LEN) {
        Ok(r) => r,
        Err(e) => {
            log!("control", "receive failed: {e}");
            reply(
                &mut stream,
                &protocol::error_line(format!("receive failed: {e}")),
            );
            return;
        }
    };

    let (line, after) = dispatch(&received.line, received.fds, &stream, state);
    reply(&mut stream, &line);

    match after {
        After::Nothing => {}
        After::CloseFd(fd) => {
            log!("handoff", "reply sent: {}", line.trim_end());
            drop(fd);
            log!(
                "handoff",
                "closed our copy of the fd; plymouth left as it is"
            );
        }
        After::FinishHandoff(fd, recorded) => {
            log!("handoff", "reply sent: {}", line.trim_end());
            // The reply must not wait for the frontend's first commit, but
            // the fd must stay open until it is seen; finish() closes it.
            let spawned = thread::Builder::new()
                .name("handoff-finish".into())
                .spawn(move || handoff::finish(fd, recorded));
            if let Err(e) = spawned {
                log!(
                    "handoff",
                    "cannot spawn the finish thread ({e}); retiring plymouth now"
                );
                handoff::retire_plymouth();
            }
        }
    }
}

fn dispatch(line: &[u8], fds: Vec<OwnedFd>, stream: &UnixStream, state: &State) -> (String, After) {
    let op = match protocol::parse_request(line) {
        Ok(op) => op,
        Err(e) => {
            log!("control", "bad request: {e}");
            return (protocol::error_line(e), After::Nothing);
        }
    };

    // Descriptors only mean something to drm-handoff; any others are closed
    // here, when `fds` drops.
    match op {
        Op::Ping => {
            let mut fields = Map::new();
            fields.insert("version".into(), json!(settings::VERSION));
            (protocol::ok_line(fields), After::Nothing)
        }
        Op::FormatSd | Op::EjectSd => {
            let command = if matches!(op, Op::FormatSd) {
                "format-sd"
            } else {
                "eject-sd"
            };
            let reply = match std::process::Command::new("/usr/local/lib/tempo-system/tempo-system")
                .arg(command)
                .output()
            {
                Ok(output) if output.status.success() => protocol::ok_line(Map::new()),
                Ok(output) => protocol::error_line(String::from_utf8_lossy(&output.stderr).trim()),
                Err(error) => protocol::error_line(error.to_string()),
            };
            (reply, After::Nothing)
        }
        Op::Power(action) => {
            let reply = match crate::power::request(action) {
                Ok(()) => protocol::ok_line(Map::new()),
                Err(error) => protocol::error_line(error),
            };
            (reply, After::Nothing)
        }
        Op::FirstRun(pending) => {
            let first_run = first_run::FirstRun::default();
            let reply = match pending {
                None => protocol::ok_line(first_run.status()),
                Some(pending) => match first_run.queue(&pending) {
                    Ok(()) => protocol::ok_line(Map::new()),
                    Err(error) => protocol::error_line(error),
                },
            };
            (reply, After::Nothing)
        }
        Op::Timezone(zone) => {
            let reply = match timezone::set(&zone) {
                Ok(()) => protocol::ok_line(Map::from_iter([("zone".into(), json!(zone))])),
                Err(error) => protocol::error_line(error),
            };
            (reply, After::Nothing)
        }
        Op::Battery => {
            // Read now, not the sampler's last word: a sample is a few
            // sysfs reads, and the charger's plug is the kind of thing the
            // bar must not show half a minute late. The sampler keeps its
            // own schedule for the store.
            let sample = Sample::read(&state.sysfs);
            if let Ok(mut latest) = state.latest.lock() {
                *latest = Some(sample.clone());
            }
            (protocol::ok_line(sample.fields()), After::Nothing)
        }
        Op::DrmHandoff => {
            if let Some((uid, gid, pid)) = peer_credentials(stream) {
                log!("handoff", "requested by pid {pid} (uid {uid}, gid {gid})");
            }
            let mut fds = fds.into_iter();
            let Some(fd) = fds.next() else {
                log!("handoff", "request carried no file descriptor");
                return (
                    protocol::error_line("drm-handoff: no file descriptor received"),
                    After::Nothing,
                );
            };
            let extra = fds.count();
            if extra > 0 {
                log!("handoff", "ignoring {extra} extra descriptor(s)");
            }
            let _serialized = state.handoff.lock().unwrap_or_else(|e| e.into_inner());
            match handoff::perform(fd.as_fd()) {
                Ok(recorded) => (protocol::ok_empty(), After::FinishHandoff(fd, recorded)),
                Err(e) => (protocol::error_line(e), After::CloseFd(fd)),
            }
        }
        Op::Screen(req) => {
            let Some(dir) = &state.sysfs.backlight else {
                log!("screen", "request but no backlight device");
                return (
                    protocol::error_line("screen: no backlight device"),
                    After::Nothing,
                );
            };
            if req.on.is_some() || req.brightness.is_some() {
                if let Some((uid, _, pid)) = peer_credentials(stream) {
                    log!("screen", "{req:?} from pid {pid} (uid {uid})");
                }
            }
            match state.screen.apply(dir, &req) {
                Ok(status) => (protocol::ok_line(status.fields()), After::Nothing),
                Err(e) => {
                    log!("screen", "{e}");
                    (protocol::error_line(format!("screen: {e}")), After::Nothing)
                }
            }
        }
        Op::Volume(req) => {
            if req.level.is_some() || req.step.is_some() {
                if let Some((uid, _, pid)) = peer_credentials(stream) {
                    log!("volume", "{req:?} from pid {pid} (uid {uid})");
                }
            }
            // Polls reuse the PipeWire monitor instead of spawning wpctl.
            let result = if req.level.is_none() && req.step.is_none() {
                state
                    .routing
                    .volume()
                    .map(Ok)
                    .unwrap_or_else(|| state.volume.apply(&req))
            } else {
                state.volume.apply(&req).map(|mut status| {
                    if let Some(context) = state.routing.volume() {
                        status.device = context.device;
                        status.hardware = context.hardware;
                    }
                    status
                })
            };
            match result {
                Ok(status) => (protocol::ok_line(status.fields()), After::Nothing),
                Err(e) => {
                    log!("volume", "{e}");
                    (protocol::error_line(format!("volume: {e}")), After::Nothing)
                }
            }
        }
        Op::Output(target) => match state.routing.apply(target.as_deref()) {
            Ok(fields) => (protocol::ok_line(fields), After::Nothing),
            Err(e) => (protocol::error_line(format!("output: {e}")), After::Nothing),
        },
        Op::Haptic(req) => match state.haptic.apply(&req) {
            Ok(status) => (protocol::ok_line(status.fields()), After::Nothing),
            Err(e) => {
                log!("haptic", "{e}");
                (protocol::error_line(format!("haptic: {e}")), After::Nothing)
            }
        },
        Op::Sound(name, speaker_only) => match state.sound.play(name, speaker_only) {
            Ok(()) => (protocol::ok_empty(), After::Nothing),
            Err(e) => {
                log!("sound", "{e}");
                (protocol::error_line(format!("sound: {e}")), After::Nothing)
            }
        },
        Op::Fm(request) => {
            if request.on.is_some() || request.frequency_khz.is_some() || request.seek.is_some() {
                if let Some((uid, _, pid)) = peer_credentials(stream) {
                    log!("fm", "{request:?} from pid {pid} (uid {uid})");
                }
            }
            match state.radio.apply(&request) {
                Ok(status) => (protocol::ok_line(status.fields()), After::Nothing),
                Err(error) => {
                    log!("fm", "{error}");
                    (protocol::error_line(format!("fm: {error}")), After::Nothing)
                }
            }
        }
        Op::Unknown(name) => {
            log!("control", "unknown op {name:?}");
            (protocol::error_line("unknown op"), After::Nothing)
        }
    }
}

fn reply(stream: &mut UnixStream, line: &str) {
    if let Err(e) = stream
        .write_all(line.as_bytes())
        .and_then(|_| stream.flush())
    {
        log!("control", "reply not delivered: {e}");
    }
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

/// (uid, gid, pid) of the peer, via SO_PEERCRED.
pub fn peer_credentials(stream: &UnixStream) -> Option<(u32, u32, i32)> {
    // SAFETY: getsockopt into a correctly sized ucred.
    let mut cred: libc::ucred = unsafe { zeroed() };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (rc == 0).then_some((cred.uid, cred.gid, cred.pid))
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader};

    use serde_json::Value;

    use super::*;

    fn state() -> State {
        State::new(Sysfs::default())
    }

    fn roundtrip(request: &[u8], fds: &[std::os::fd::RawFd]) -> Value {
        let (client, server) = UnixStream::pair().unwrap();
        fdpass::send_with_fds(&client, request, fds).unwrap();
        let st = state();
        let worker = thread::spawn(move || handle(server, &st));
        let mut line = String::new();
        BufReader::new(&client).read_line(&mut line).unwrap();
        worker.join().unwrap();
        assert!(
            line.ends_with('\n'),
            "reply is newline-terminated: {line:?}"
        );
        serde_json::from_str(line.trim_end()).unwrap()
    }

    #[test]
    fn ping() {
        let v = roundtrip(b"{\"op\":\"ping\"}\n", &[]);
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["version"], json!(settings::VERSION));
    }

    #[test]
    fn battery_answers_even_before_the_first_sample() {
        let v = roundtrip(b"{\"op\":\"battery\"}\n", &[]);
        assert_eq!(v["ok"], json!(true));
        assert!(v["ts"].is_i64());
        assert!(v.get("capacity").is_some());
    }

    #[test]
    fn battery_reads_the_gauge_now_not_the_sampler_s_last_word() {
        let (client, server) = UnixStream::pair().unwrap();
        let st = state();
        let stale = Sample {
            ts: 42,
            capacity: Some(77),
            ..Default::default()
        };
        *st.latest.lock().unwrap() = Some(stale);
        let latest = st.latest.clone();
        let worker = thread::spawn(move || handle(server, &st));
        fdpass::send_with_fds(&client, b"{\"op\":\"battery\"}\n", &[]).unwrap();
        let mut line = String::new();
        BufReader::new(&client).read_line(&mut line).unwrap();
        worker.join().unwrap();
        let v: Value = serde_json::from_str(line.trim_end()).unwrap();
        // A fresh reading: stamped now, and - with no gauge in the test
        // environment - carrying no capacity at all.
        assert_ne!(v["ts"], json!(42));
        assert!(v.get("capacity").is_none() || v["capacity"].is_null());
        // And the sampler's latest is the fresh one now too.
        assert_ne!(latest.lock().unwrap().as_ref().unwrap().ts, 42);
    }

    #[test]
    fn unknown_and_malformed() {
        let v = roundtrip(b"{\"op\":\"unsupported\"}\n", &[]);
        assert_eq!(v, json!({"ok": false, "error": "unknown op"}));
        let v = roundtrip(b"{not json\n", &[]);
        assert_eq!(v["ok"], json!(false));
        assert!(
            v["error"]
                .as_str()
                .unwrap()
                .starts_with("malformed request")
        );
        let v = roundtrip(b"\n", &[]);
        assert_eq!(v, json!({"ok": false, "error": "empty request"}));
    }

    #[test]
    fn screen_without_a_backlight_is_an_error() {
        let v = roundtrip(b"{\"op\":\"screen\"}\n", &[]);
        assert_eq!(
            v,
            json!({"ok": false, "error": "screen: no backlight device"})
        );
    }

    #[test]
    fn screen_off_and_on_through_the_socket() {
        let dir = std::env::temp_dir().join(format!("tempod-ctl-screen-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("brightness"), "100\n").unwrap();
        fs::write(dir.join("max_brightness"), "124\n").unwrap();
        fs::write(dir.join("bl_power"), "0\n").unwrap();
        let st = Arc::new(State::new(Sysfs {
            battery: None,
            backlight: Some(dir.clone()),
        }));

        let ask = |line: &[u8]| -> Value {
            let (client, server) = UnixStream::pair().unwrap();
            fdpass::send_with_fds(&client, line, &[]).unwrap();
            let st = Arc::clone(&st);
            let worker = thread::spawn(move || handle(server, &st));
            let mut reply = String::new();
            BufReader::new(&client).read_line(&mut reply).unwrap();
            worker.join().unwrap();
            serde_json::from_str(reply.trim_end()).unwrap()
        };

        let v = ask(b"{\"op\":\"screen\"}\n");
        assert_eq!(
            v,
            json!({"ok": true, "on": true, "brightness": 100, "max": 124})
        );
        let v = ask(b"{\"op\":\"screen\",\"on\":false,\"fade_ms\":20}\n");
        assert_eq!(
            v,
            json!({"ok": true, "on": false, "brightness": 100, "max": 124})
        );
        assert_eq!(
            fs::read_to_string(dir.join("bl_power")).unwrap().trim(),
            "4"
        );
        let v = ask(b"{\"op\":\"screen\",\"on\":true,\"fade_ms\":0}\n");
        assert_eq!(
            v,
            json!({"ok": true, "on": true, "brightness": 100, "max": 124})
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn handoff_without_an_fd_is_refused() {
        let v = roundtrip(b"{\"op\":\"drm-handoff\"}\n", &[]);
        assert_eq!(v["ok"], json!(false));
        assert!(v["error"].as_str().unwrap().contains("no file descriptor"));
    }

    #[test]
    fn handoff_with_a_non_drm_fd_is_refused_before_anything_runs() {
        let null = std::fs::File::open("/dev/null").unwrap();
        let v = roundtrip(b"{\"op\":\"drm-handoff\"}\n", &[null.as_raw_fd()]);
        assert_eq!(v, json!({"ok": false, "error": "not a DRM primary node"}));
    }

    #[test]
    fn peer_credentials_are_ours() {
        let (a, _b) = UnixStream::pair().unwrap();
        let (uid, gid, pid) = peer_credentials(&a).unwrap();
        // SAFETY: getuid/getgid have no preconditions.
        assert_eq!(uid, unsafe { libc::getuid() });
        assert_eq!(gid, unsafe { libc::getgid() });
        assert_eq!(pid, std::process::id() as i32);
    }

    #[test]
    fn bind_creates_the_directory_and_replaces_a_stale_socket() {
        let dir = std::env::temp_dir().join(format!("tempod-ctl-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = dir.join("sub").join("tempod.sock");
        let first = bind(&path).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o660
        );
        drop(first);
        // The socket file is still there (an unclean exit); binding again
        // works.
        assert!(fs::symlink_metadata(&path).unwrap().file_type().is_socket());
        let second = bind(&path).unwrap();
        drop(second);
        // A non-socket in the way is an error, not silently removed.
        fs::remove_file(&path).unwrap();
        fs::write(&path, b"x").unwrap();
        assert_eq!(
            bind(&path).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
