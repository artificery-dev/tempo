//! The helper's stdin is a tiny, one-way control channel. EOF is not
//! cancellation (standalone CLI callers may have no stdin); only a complete
//! `cancel` line is.
use std::{
    io::{self, Read},
    sync::atomic::{AtomicBool, Ordering},
};

pub fn read_cancellation(mut reader: impl Read, cancelled: &AtomicBool) -> io::Result<()> {
    let mut input = [0_u8; 64];
    let mut line = [0_u8; 16];
    let mut length = 0;
    let mut oversized = false;
    loop {
        let count = match reader.read(&mut input) {
            Ok(0) => return Ok(()),
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        for &byte in &input[..count] {
            if byte == b'\n' {
                if !oversized && matches!(&line[..length], b"cancel" | b"cancel\r") {
                    cancelled.store(true, Ordering::Relaxed);
                    return Ok(());
                }
                length = 0;
                oversized = false;
            } else if length < line.len() && !oversized {
                line[length] = byte;
                length += 1;
            } else {
                oversized = true;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn accepts_only_complete_cancel_lines() {
        for input in [b"cancel\n".as_slice(), b"cancel\r\n", b"unknown\ncancel\n"] {
            let flag = AtomicBool::new(false);
            read_cancellation(Cursor::new(input), &flag).unwrap();
            assert!(flag.load(Ordering::Relaxed));
        }
        for input in [
            b"".as_slice(),
            b"cancel",
            b" cancel\n",
            b"cancelled\n",
            b"\xff\n",
        ] {
            let flag = AtomicBool::new(false);
            read_cancellation(Cursor::new(input), &flag).unwrap();
            assert!(!flag.load(Ordering::Relaxed));
        }
    }

    #[test]
    fn oversized_lines_are_discarded_without_accepting_a_suffix() {
        let mut input = vec![b'x'; 1024 * 1024];
        input.extend_from_slice(b"cancel\n");
        let flag = AtomicBool::new(false);
        read_cancellation(Cursor::new(&input), &flag).unwrap();
        assert!(!flag.load(Ordering::Relaxed));
        input.extend_from_slice(b"cancel\n");
        read_cancellation(Cursor::new(input), &flag).unwrap();
        assert!(flag.load(Ordering::Relaxed));
    }

    struct Fragmented {
        bytes: Cursor<Vec<u8>>,
        interrupt: bool,
    }
    impl Read for Fragmented {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            if self.interrupt {
                self.interrupt = false;
                return Err(io::ErrorKind::Interrupted.into());
            }
            self.bytes.read(&mut output[..1])
        }
    }
    #[test]
    fn handles_fragmented_input_and_interrupted_reads() {
        let flag = AtomicBool::new(false);
        read_cancellation(
            Fragmented {
                bytes: Cursor::new(b"cancel\r\n".to_vec()),
                interrupt: true,
            },
            &flag,
        )
        .unwrap();
        assert!(flag.load(Ordering::Relaxed));
    }
}
