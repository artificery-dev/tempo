//! Versioned C ABI for the Dart host. The old executable remains available
//! while metrics and service orchestration migrate. This runtime hosts the
//! existing control protocol only; it does not start the metrics sampler.
use std::{
    ffi::{CStr, c_char},
    io,
    os::{
        fd::FromRawFd,
        unix::net::{UnixListener, UnixStream},
    },
    path::Path,
    ptr,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use crate::{activation, control, metrics};

pub struct Runtime {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

/// ABI 1: opaque, single-owner runtime handles. start consumes activated_fd
/// on success only; -1 binds path instead. stop consumes the runtime handle.
#[no_mangle]
pub extern "C" fn tempod_native_abi_version() -> u32 {
    1
}

/// # Safety
/// path must be a valid NUL-terminated UTF-8 string when fd is -1. error must
/// reference error_capacity writable bytes, or be null with capacity zero.
/// The caller transfers an inherited Unix listening fd on successful start.
#[no_mangle]
pub unsafe extern "C" fn tempod_native_start(
    path: *const c_char,
    activated_fd: i32,
    error: *mut c_char,
    error_capacity: usize,
) -> *mut Runtime {
    // Never unwind across FFI. Release builds abort on panic; ordinary I/O
    // failures are returned normally through the caller-owned error buffer.
    let result = std::panic::catch_unwind(|| -> Result<Runtime, String> {
        let listener = if activated_fd >= 0 {
            let mut accepting: libc::c_int = 0;
            let mut length = std::mem::size_of_val(&accepting) as libc::socklen_t;
            let listening = unsafe {
                libc::getsockopt(
                    activated_fd,
                    libc::SOL_SOCKET,
                    libc::SO_ACCEPTCONN,
                    (&mut accepting as *mut libc::c_int).cast(),
                    &mut length,
                )
            } == 0
                && accepting == 1;
            if !activation::is_unix_stream(activated_fd) || !listening {
                return Err("activation fd is not a Unix listening socket".into());
            }
            // Duplicate first: an error leaves the caller's original intact.
            let duplicate = unsafe { libc::fcntl(activated_fd, libc::F_DUPFD_CLOEXEC, 3) };
            if duplicate < 0 {
                return Err(io::Error::last_os_error().to_string());
            }
            unsafe { UnixListener::from_raw_fd(duplicate) }
        } else {
            if path.is_null() {
                return Err("socket path is required".into());
            }
            let path = unsafe { CStr::from_ptr(path) }
                .to_str()
                .map_err(|_| "invalid UTF-8 socket path")?;
            if path.is_empty() {
                return Err("socket path is empty".into());
            }
            // Do not unlink the active daemon's socket during development.
            match UnixStream::connect(path) {
                Ok(_) => return Err("a daemon is already listening on this socket".into()),
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    ) => {}
                Err(e) => return Err(e.to_string()),
            }
            control::bind(Path::new(path)).map_err(|e| e.to_string())?
        };
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);
        let state = Arc::new(control::State::new(metrics::Sysfs::discover(|k| {
            std::env::var(k).ok()
        })));
        let thread = thread::Builder::new()
            .name("native-control".into())
            .spawn(move || {
                let mut workers: Vec<JoinHandle<()>> = Vec::new();
                while !stopping.load(Ordering::Acquire) {
                    let mut i = 0;
                    while i < workers.len() {
                        if workers[i].is_finished() {
                            let _ = workers.swap_remove(i).join();
                        } else {
                            i += 1;
                        }
                    }
                    match listener.accept() {
                        Ok((stream, _)) => {
                            if workers.len() >= 32 {
                                drop(stream);
                                continue;
                            }
                            // Accepted sockets must use the existing blocking
                            // handlers.
                            if stream.set_nonblocking(false).is_err() {
                                continue;
                            }
                            let state = Arc::clone(&state);
                            match thread::Builder::new()
                                .name("native-request".into())
                                .spawn(move || control::handle(stream, &state))
                            {
                                Ok(worker) => workers.push(worker),
                                Err(e) => log!("native", "cannot start handler: {e}"),
                            }
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(10))
                        }
                        Err(e) => {
                            log!("native", "accept: {e}");
                            thread::sleep(Duration::from_millis(100));
                        }
                    }
                }
                drop(listener);
                for worker in workers {
                    let _ = worker.join();
                }
            })
            .map_err(|e| e.to_string())?;
        if activated_fd >= 0 {
            unsafe {
                libc::close(activated_fd);
            }
        }
        Ok(Runtime {
            stop,
            thread: Some(thread),
        })
    });
    let message = match result {
        Ok(Ok(runtime)) => return Box::into_raw(Box::new(runtime)),
        Ok(Err(message)) => message,
        Err(_) => "native startup panicked".into(),
    };
    if !error.is_null() && error_capacity > 0 {
        let bytes = message.as_bytes();
        let n = bytes.len().min(error_capacity - 1);
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), error.cast::<u8>(), n);
            *error.add(n) = 0;
        }
    }
    ptr::null_mut()
}

/// Stop accepting and wait for in-flight control requests. Call on a worker
/// isolate: existing native operations may block. Native handoff completion
/// threads retain their existing lifetime and finish independently.
///
/// # Safety
/// runtime must be a handle returned by start, passed exactly once to stop.
#[no_mangle]
pub unsafe extern "C" fn tempod_native_stop(runtime: *mut Runtime) {
    if runtime.is_null() {
        return;
    }
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut runtime = unsafe { Box::from_raw(runtime) };
        runtime.stop.store(true, Ordering::Release);
        if let Some(thread) = runtime.thread.take() {
            let _ = thread.join();
        }
    }));
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::CString,
        io::{BufRead, BufReader, Write},
    };

    use super::*;

    #[test]
    fn abi_preserves_control_ping_and_refuses_a_second_listener() {
        let dir = std::env::temp_dir().join(format!("tempod-ffi-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("control.sock");
        let cpath = CString::new(path.to_str().unwrap()).unwrap();
        let mut error = [0 as c_char; 512];
        assert_eq!(tempod_native_abi_version(), 1);
        let handle =
            unsafe { tempod_native_start(cpath.as_ptr(), -1, error.as_mut_ptr(), error.len()) };
        assert!(!handle.is_null());
        let mut client = UnixStream::connect(&path).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        client.write_all(b"{\"op\":\"ping\"}\n").unwrap();
        let mut response = String::new();
        BufReader::new(client).read_line(&mut response).unwrap();
        let reply: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(reply["ok"], true);
        let second =
            unsafe { tempod_native_start(cpath.as_ptr(), -1, error.as_mut_ptr(), error.len()) };
        assert!(second.is_null());
        unsafe {
            tempod_native_stop(handle);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn activated_listener_transfers_ownership_and_serves_the_existing_protocol() {
        use std::os::fd::IntoRawFd;
        let dir = std::env::temp_dir().join(format!("tempod-activation-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("control.sock");
        let fd = UnixListener::bind(&path).unwrap().into_raw_fd();
        let mut error = [0 as c_char; 512];
        let handle =
            unsafe { tempod_native_start(ptr::null(), fd, error.as_mut_ptr(), error.len()) };
        assert!(!handle.is_null());
        assert_eq!(unsafe { libc::fcntl(fd, libc::F_GETFD) }, -1);
        let mut client = UnixStream::connect(&path).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        client.write_all(b"{\"op\":\"ping\"}\n").unwrap();
        let mut response = String::new();
        BufReader::new(client).read_line(&mut response).unwrap();
        let reply: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(reply["ok"], true);
        unsafe {
            tempod_native_stop(handle);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_connected_socket_is_not_an_activation_listener_and_remains_owned_by_caller() {
        use std::os::fd::AsRawFd;
        let (client, _server) = UnixStream::pair().unwrap();
        let mut error = [0 as c_char; 512];
        let handle = unsafe {
            tempod_native_start(
                ptr::null(),
                client.as_raw_fd(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        assert!(handle.is_null());
        assert!(unsafe { libc::fcntl(client.as_raw_fd(), libc::F_GETFD) } >= 0);
    }

    #[test]
    fn abi_returns_a_bounded_error_for_invalid_startup() {
        let mut error = [0 as c_char; 8];
        let handle =
            unsafe { tempod_native_start(ptr::null(), -1, error.as_mut_ptr(), error.len()) };
        assert!(handle.is_null());
        assert_eq!(error[7], 0);
        assert_ne!(error[0], 0);
    }
}
