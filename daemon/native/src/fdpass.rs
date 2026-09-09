//! Receiving a request line together with any file descriptors the client
//! attached to it as SCM_RIGHTS ancillary data - how `drm-handoff` gets the
//! frontend's DRM fd.
//!
//! The client sends its request bytes with `sendmsg` and the fd in the
//! control message. On a stream socket that control message is delivered
//! with the `recvmsg` that consumes the first byte of that send, so the
//! request is read with `recvmsg` chunk by chunk until the newline, and
//! every chunk's control data is harvested along the way.

use std::{
    io,
    mem::{size_of, zeroed},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
        unix::net::UnixStream,
    },
};

/// The most descriptors one request may carry; `drm-handoff` sends one.
/// More than this is MSG_CTRUNC and an error.
pub const MAX_FDS: usize = 4;

/// Room for the control message. CMSG_SPACE(MAX_FDS ints) is 32 bytes on
/// both LP64 and ILP32 Linux; this leaves slack and is checked at runtime.
const CMSG_BUF_LEN: usize = 256;

/// Control-message buffer, aligned as `struct cmsghdr` requires.
#[repr(C, align(8))]
struct CmsgBuf([u8; CMSG_BUF_LEN]);

#[derive(Debug)]
pub struct Received {
    /// The request line, without its terminating newline.
    pub line: Vec<u8>,
    /// Every descriptor passed with it, in order, CLOEXEC set.
    pub fds: Vec<OwnedFd>,
}

/// Read one newline-terminated request from `sock` along with any passed
/// descriptors. EOF before a newline ends the line too. Longer than
/// `max_len` bytes, or more descriptors than [`MAX_FDS`], is an error.
pub fn recv_line(sock: &UnixStream, max_len: usize) -> io::Result<Received> {
    let fd = sock.as_raw_fd();
    let mut line = Vec::new();
    let mut fds = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let chunk = recv_chunk(fd, &mut buf)?;
        fds.extend(chunk.fds);
        if chunk.truncated {
            // What fit is in `fds` and closes on drop; what did not, the
            // kernel already closed. Either way the request is not what the
            // client meant to send.
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("ancillary data truncated: more than {MAX_FDS} file descriptors"),
            ));
        }
        if chunk.len == 0 {
            break;
        }
        line.extend_from_slice(&buf[..chunk.len]);
        if let Some(nl) = line.iter().position(|&b| b == b'\n') {
            line.truncate(nl);
            break;
        }
        if line.len() > max_len {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("request exceeds {max_len} bytes without a newline"),
            ));
        }
    }
    Ok(Received { line, fds })
}

struct Chunk {
    len: usize,
    fds: Vec<OwnedFd>,
    truncated: bool,
}

fn recv_chunk(fd: RawFd, buf: &mut [u8]) -> io::Result<Chunk> {
    let mut control = CmsgBuf([0; CMSG_BUF_LEN]);
    // SAFETY: CMSG_SPACE is pure arithmetic.
    let controllen = unsafe { libc::CMSG_SPACE((MAX_FDS * size_of::<RawFd>()) as u32) } as usize;
    assert!(
        controllen <= CMSG_BUF_LEN,
        "control buffer too small for MAX_FDS"
    );

    let mut iov = libc::iovec {
        iov_base: buf.as_mut_ptr().cast(),
        iov_len: buf.len(),
    };
    // SAFETY: msghdr is plain data; every field we rely on is set below.
    let mut msg: libc::msghdr = unsafe { zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.0.as_mut_ptr().cast();
    msg.msg_controllen = controllen as _;

    let len = loop {
        // SAFETY: msg points at live, correctly sized buffers for the call.
        let n = unsafe { libc::recvmsg(fd, &mut msg, libc::MSG_CMSG_CLOEXEC) };
        if n >= 0 {
            break n as usize;
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    };
    // SAFETY: the kernel filled msg_control/msg_controllen for this msghdr.
    let fds = unsafe { collect_fds(&msg) };
    Ok(Chunk {
        len,
        fds,
        truncated: msg.msg_flags & libc::MSG_CTRUNC != 0,
    })
}

/// Walk the control messages of a received `msghdr` and take ownership of
/// every SCM_RIGHTS descriptor in them.
///
/// # Safety
/// `msg` must have been filled in by a successful `recvmsg`.
unsafe fn collect_fds(msg: &libc::msghdr) -> Vec<OwnedFd> {
    let mut fds = Vec::new();
    let mut cmsg = libc::CMSG_FIRSTHDR(msg);
    while !cmsg.is_null() {
        let hdr = &*cmsg;
        if hdr.cmsg_level == libc::SOL_SOCKET && hdr.cmsg_type == libc::SCM_RIGHTS {
            // cmsg_len covers the header and the payload; the header's size
            // is CMSG_LEN(0), and the payload is an array of int.
            let header = libc::CMSG_LEN(0) as usize;
            let payload = (hdr.cmsg_len as usize).saturating_sub(header);
            let data = libc::CMSG_DATA(cmsg) as *const RawFd;
            for i in 0..payload / size_of::<RawFd>() {
                let raw = std::ptr::read_unaligned(data.add(i));
                if raw >= 0 {
                    fds.push(OwnedFd::from_raw_fd(raw));
                }
            }
        }
        cmsg = libc::CMSG_NXTHDR(msg, cmsg);
    }
    fds
}

/// Send `data` with `fds` attached as SCM_RIGHTS - the client side of the
/// contract, used by the tests to exercise the receive side.
#[cfg(test)]
pub(crate) fn send_with_fds(sock: &UnixStream, data: &[u8], fds: &[RawFd]) -> io::Result<usize> {
    let mut control = CmsgBuf([0; CMSG_BUF_LEN]);
    let payload = std::mem::size_of_val(fds) as u32;
    let space = unsafe { libc::CMSG_SPACE(payload) } as usize;
    assert!(space <= CMSG_BUF_LEN);

    let mut iov = libc::iovec {
        iov_base: data.as_ptr() as *mut _,
        iov_len: data.len(),
    };
    let mut msg: libc::msghdr = unsafe { zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    if !fds.is_empty() {
        msg.msg_control = control.0.as_mut_ptr().cast();
        msg.msg_controllen = space as _;
        unsafe {
            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN(payload) as _;
            std::ptr::copy_nonoverlapping(
                fds.as_ptr(),
                libc::CMSG_DATA(cmsg) as *mut RawFd,
                fds.len(),
            );
        }
    }
    let n = unsafe { libc::sendmsg(sock.as_raw_fd(), &msg, libc::MSG_NOSIGNAL) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(n as usize)
}

#[cfg(test)]
mod tests {
    use std::{fs::File, io::Write, os::unix::fs::MetadataExt};

    use super::*;

    fn dev_null() -> File {
        File::options()
            .read(true)
            .write(true)
            .open("/dev/null")
            .unwrap()
    }

    fn same_file(a: &File, b: &File) -> bool {
        let (ma, mb) = (a.metadata().unwrap(), b.metadata().unwrap());
        ma.dev() == mb.dev() && ma.ino() == mb.ino()
    }

    #[test]
    fn request_with_one_fd() {
        let (client, server) = UnixStream::pair().unwrap();
        let null = dev_null();
        send_with_fds(&client, b"{\"op\":\"drm-handoff\"}\n", &[null.as_raw_fd()]).unwrap();

        let got = recv_line(&server, 1024).unwrap();
        assert_eq!(got.line, b"{\"op\":\"drm-handoff\"}");
        assert_eq!(got.fds.len(), 1);

        let fd = got.fds.into_iter().next().unwrap();
        // CLOEXEC: nothing we exec (plymouth) may inherit the frontend's fd.
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
        assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0);
        // It is a duplicate of the sender's /dev/null, and usable.
        let mut received = File::from(fd);
        assert!(same_file(&received, &null));
        assert_eq!(received.write(b"x").unwrap(), 1);
    }

    #[test]
    fn request_without_fds() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .write_all(b"{\"op\":\"ping\"}\ntrailing garbage")
            .unwrap();
        let got = recv_line(&server, 1024).unwrap();
        assert_eq!(got.line, b"{\"op\":\"ping\"}");
        assert!(got.fds.is_empty());
    }

    #[test]
    fn request_split_across_sends_keeps_the_fd() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let null = dev_null();
        client.write_all(b"{\"op\":").unwrap();
        send_with_fds(&client, b"\"drm-handoff\"}\n", &[null.as_raw_fd()]).unwrap();
        let got = recv_line(&server, 1024).unwrap();
        assert_eq!(got.line, b"{\"op\":\"drm-handoff\"}");
        assert_eq!(got.fds.len(), 1);
    }

    #[test]
    fn several_fds_arrive_in_order() {
        let (client, server) = UnixStream::pair().unwrap();
        let null = dev_null();
        let zero = File::open("/dev/zero").unwrap();
        send_with_fds(&client, b"x\n", &[null.as_raw_fd(), zero.as_raw_fd()]).unwrap();
        let got = recv_line(&server, 1024).unwrap();
        assert_eq!(got.fds.len(), 2);
        let mut it = got.fds.into_iter().map(File::from);
        assert!(same_file(&it.next().unwrap(), &null));
        assert!(same_file(&it.next().unwrap(), &zero));
    }

    #[test]
    fn too_many_fds_is_truncation() {
        let (client, server) = UnixStream::pair().unwrap();
        let null = dev_null();
        let fds = vec![null.as_raw_fd(); MAX_FDS + 1];
        send_with_fds(&client, b"x\n", &fds).unwrap();
        let err = recv_line(&server, 1024).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(err.to_string().contains("truncated"), "{err}");
    }

    #[test]
    fn eof_terminates_a_line_without_newline() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client.write_all(b"{\"op\":\"ping\"}").unwrap();
        drop(client);
        let got = recv_line(&server, 1024).unwrap();
        assert_eq!(got.line, b"{\"op\":\"ping\"}");
    }

    #[test]
    fn empty_connection_is_an_empty_line() {
        let (client, server) = UnixStream::pair().unwrap();
        drop(client);
        let got = recv_line(&server, 1024).unwrap();
        assert!(got.line.is_empty());
        assert!(got.fds.is_empty());
    }

    #[test]
    fn oversized_request_is_rejected() {
        let (mut client, server) = UnixStream::pair().unwrap();
        client.write_all(&[b'a'; 100]).unwrap();
        drop(client);
        let err = recv_line(&server, 10).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }
}
