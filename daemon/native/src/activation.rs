//! systemd socket activation: take the listening socket tempod.socket
//! hands us instead of binding our own.
//!
//! The contract (sd_listen_fds) is small: if `LISTEN_PID` is our pid, then
//! `LISTEN_FDS` descriptors starting at fd 3 are ours. We use the first,
//! check it really is a unix stream socket, and scrub the variables so
//! nothing we spawn later (plymouth, for one) inherits them.

use std::{
    ffi::c_void,
    mem::{size_of, zeroed},
    os::{
        fd::{FromRawFd, RawFd},
        unix::net::UnixListener,
    },
};

/// The first descriptor systemd passes (SD_LISTEN_FDS_START).
pub const LISTEN_FDS_START: RawFd = 3;

/// How many descriptors systemd passed to *this* process, from the raw
/// `LISTEN_PID` / `LISTEN_FDS` values. Zero unless both are present, the pid
/// is ours, and the count parses.
pub fn activated_fd_count(
    listen_pid: Option<&str>,
    listen_fds: Option<&str>,
    our_pid: u32,
) -> usize {
    let pid: u32 = match listen_pid.and_then(|p| p.trim().parse().ok()) {
        Some(pid) => pid,
        None => return 0,
    };
    if pid != our_pid {
        return 0;
    }
    listen_fds.and_then(|n| n.trim().parse().ok()).unwrap_or(0)
}

/// The socket-activated listener, if systemd gave us one. Always scrubs the
/// `LISTEN_*` variables. Must be called before any thread is spawned.
pub fn take_listener() -> Option<UnixListener> {
    let count = activated_fd_count(
        std::env::var("LISTEN_PID").ok().as_deref(),
        std::env::var("LISTEN_FDS").ok().as_deref(),
        std::process::id(),
    );
    for key in ["LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"] {
        std::env::remove_var(key);
    }
    if count == 0 {
        return None;
    }
    if count > 1 {
        log!("control", "systemd passed {count} sockets; using the first");
    }
    let fd = LISTEN_FDS_START;
    if !is_unix_stream(fd) {
        log!(
            "control",
            "fd {fd} from systemd is not a unix stream socket; binding our own"
        );
        return None;
    }
    set_cloexec(fd);
    // SAFETY: fd 3 is ours by the sd_listen_fds contract, checked above to be
    // a unix stream socket, and nothing else in this process refers to it.
    Some(unsafe { UnixListener::from_raw_fd(fd) })
}

/// Is `fd` an AF_UNIX SOCK_STREAM socket?
pub fn is_unix_stream(fd: RawFd) -> bool {
    let mut ty: libc::c_int = 0;
    let mut len = size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: plain getsockopt into a correctly sized local.
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_TYPE,
            (&mut ty as *mut libc::c_int).cast::<c_void>(),
            &mut len,
        )
    };
    if rc != 0 || ty != libc::SOCK_STREAM {
        return false;
    }
    // SAFETY: sockaddr_storage is large enough for any family; the length is
    // passed alongside it.
    let mut addr: libc::sockaddr_storage = unsafe { zeroed() };
    let mut alen = size_of::<libc::sockaddr_storage>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockname(
            fd,
            (&mut addr as *mut libc::sockaddr_storage).cast(),
            &mut alen,
        )
    };
    rc == 0 && addr.ss_family == libc::AF_UNIX as libc::sa_family_t
}

fn set_cloexec(fd: RawFd) {
    // SAFETY: fcntl on a descriptor we own; failure is only logged.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags < 0 || libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) < 0 {
            log!(
                "control",
                "cannot set CLOEXEC on fd {fd}: {}",
                std::io::Error::last_os_error()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{net::TcpListener, os::fd::AsRawFd};

    use super::*;

    #[test]
    fn count_requires_our_pid() {
        assert_eq!(activated_fd_count(Some("123"), Some("1"), 123), 1);
        assert_eq!(activated_fd_count(Some(" 123 "), Some(" 2 "), 123), 2);
        assert_eq!(
            activated_fd_count(Some("124"), Some("1"), 123),
            0,
            "another pid"
        );
        assert_eq!(activated_fd_count(None, Some("1"), 123), 0, "no pid");
        assert_eq!(activated_fd_count(Some("123"), None, 123), 0, "no count");
        assert_eq!(activated_fd_count(Some("123"), Some("0"), 123), 0);
        assert_eq!(activated_fd_count(Some("abc"), Some("1"), 123), 0);
        assert_eq!(activated_fd_count(Some("123"), Some("many"), 123), 0);
        assert_eq!(activated_fd_count(Some(""), Some(""), 123), 0);
    }

    #[test]
    fn recognizes_a_unix_stream_socket() {
        let dir = std::env::temp_dir().join(format!("tempod-act-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s");
        let listener = UnixListener::bind(&path).unwrap();
        assert!(is_unix_stream(listener.as_raw_fd()));
        drop(listener);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_other_descriptors() {
        let null = std::fs::File::open("/dev/null").unwrap();
        assert!(!is_unix_stream(null.as_raw_fd()), "not a socket");
        let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
        assert!(!is_unix_stream(tcp.as_raw_fd()), "wrong family");
        assert!(!is_unix_stream(-1), "invalid fd");
    }

    #[test]
    fn no_activation_without_the_variables() {
        // The test harness never sets LISTEN_*; make sure of it, then check
        // that nothing is taken (fd 3 in a test process is not ours).
        std::env::remove_var("LISTEN_PID");
        std::env::remove_var("LISTEN_FDS");
        assert!(take_listener().is_none());
    }
}
