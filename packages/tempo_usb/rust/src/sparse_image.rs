//! Seekable view of Android sparse images without an expanded staging file.
use std::{
    fs::File,
    io::{self, Read, Seek, SeekFrom},
};

use crate::Result;
trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}
pub struct ImageSource {
    inner: Box<dyn ReadSeek>,
    size: u64,
}
impl ImageSource {
    pub fn raw(file: File) -> Result<Self> {
        let size = file.metadata().map_err(|e| e.to_string())?.len();
        Ok(Self {
            inner: Box::new(file),
            size,
        })
    }
    pub fn sparse(file: File, limit: u64) -> Result<Self> {
        let reader = SparseReader::new(file, limit)?;
        let size = reader.size;
        Ok(Self {
            inner: Box::new(reader),
            size,
        })
    }
    pub fn size(&self) -> u64 {
        self.size
    }
}
impl Read for ImageSource {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        self.inner.read(b)
    }
}
impl Seek for ImageSource {
    fn seek(&mut self, p: SeekFrom) -> io::Result<u64> {
        self.inner.seek(p)
    }
}
#[derive(Debug)]
enum Kind {
    Raw(u64),
    Fill([u8; 4]),
}
#[derive(Debug)]
struct Chunk {
    start: u64,
    end: u64,
    kind: Kind,
}
struct SparseReader {
    file: File,
    chunks: Vec<Chunk>,
    size: u64,
    position: u64,
}
fn word(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn half(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(b[at..at + 2].try_into().unwrap())
}
impl SparseReader {
    fn new(mut file: File, limit: u64) -> Result<Self> {
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        let input_size = file.metadata().map_err(|e| e.to_string())?.len();
        let mut h = [0u8; 28];
        file.read_exact(&mut h).map_err(|e| e.to_string())?;
        if word(&h, 0) != 0xed26ff3a
            || half(&h, 4) != 1
            || half(&h, 8) != 28
            || half(&h, 10) != 12
            || word(&h, 24) != 0
        {
            return Err("Unsupported Android sparse header/checksum".into());
        }
        let block = word(&h, 12) as u64;
        let size = block * word(&h, 16) as u64;
        if block == 0
            || !block.is_multiple_of(512)
            || size == 0
            || size > limit
            || word(&h, 20) > 262144
        {
            return Err("Sparse image exceeds limits".into());
        }
        let mut chunks = Vec::new();
        let mut end = 0u64;
        for _ in 0..word(&h, 20) {
            let mut c = [0; 12];
            file.read_exact(&mut c).map_err(|e| e.to_string())?;
            let length = word(&c, 4) as u64 * block;
            let start = end;
            end = end.checked_add(length).ok_or("Sparse image overflow")?;
            if length == 0 || end > size {
                return Err("Invalid sparse chunk size".into());
            }
            let payload = word(&c, 8) as u64;
            let at = file.stream_position().map_err(|e| e.to_string())?;
            let kind = match half(&c, 0) {
                0xcac1
                    if payload == length + 12
                        && at.checked_add(length).is_some_and(|e| e <= input_size) =>
                {
                    file.seek(SeekFrom::Start(at + length))
                        .map_err(|e| e.to_string())?;
                    Kind::Raw(at)
                }
                0xcac2 if payload == 16 => {
                    let mut pattern = [0; 4];
                    file.read_exact(&mut pattern).map_err(|e| e.to_string())?;
                    Kind::Fill(pattern)
                }
                0xcac3 if payload == 12 => Kind::Fill([0; 4]),
                _ => return Err("Unsupported or malformed Android sparse chunk".into()),
            };
            chunks.push(Chunk { start, end, kind });
        }
        if end != size || file.stream_position().map_err(|e| e.to_string())? != input_size {
            return Err("Sparse size mismatch or trailing data".into());
        }
        Ok(Self {
            file,
            chunks,
            size,
            position: 0,
        })
    }
}
impl Read for SparseReader {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        if self.position == self.size || b.is_empty() {
            return Ok(0);
        }
        let index = self.chunks.partition_point(|c| c.end <= self.position);
        let c = &self.chunks[index];
        let offset = self.position - c.start;
        let n = (c.end - self.position).min(b.len() as u64) as usize;
        match c.kind {
            Kind::Raw(at) => {
                self.file.seek(SeekFrom::Start(at + offset))?;
                self.file.read_exact(&mut b[..n])?;
            }
            Kind::Fill(pattern) => {
                for (i, v) in b[..n].iter_mut().enumerate() {
                    *v = pattern[(offset as usize + i) % 4];
                }
            }
        }
        self.position += n as u64;
        Ok(n)
    }
}
impl Seek for SparseReader {
    fn seek(&mut self, p: SeekFrom) -> io::Result<u64> {
        let next = match p {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(n) => self.size as i128 + n as i128,
            SeekFrom::Current(n) => self.position as i128 + n as i128,
        };
        if next < 0 || next > self.size as i128 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Seek outside sparse image",
            ));
        }
        self.position = next as u64;
        Ok(self.position)
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;
    fn fixture() -> (std::path::PathBuf, Vec<u8>) {
        let path = std::env::temp_dir().join(format!(
            "tempo-sparse-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut b = Vec::new();
        b.extend(0xed26ff3au32.to_le_bytes());
        for v in [1u16, 0, 28, 12] {
            b.extend(v.to_le_bytes());
        }
        for v in [512u32, 3, 3, 0] {
            b.extend(v.to_le_bytes());
        }
        for (kind, size, payload) in [
            (0xcac1u16, 524u32, vec![7; 512]),
            (0xcac2, 16, vec![1, 2, 3, 4]),
            (0xcac3, 12, vec![]),
        ] {
            b.extend(kind.to_le_bytes());
            b.extend(0u16.to_le_bytes());
            b.extend(1u32.to_le_bytes());
            b.extend(size.to_le_bytes());
            b.extend(payload);
        }
        File::create(&path).unwrap().write_all(&b).unwrap();
        let mut expected = vec![7; 512];
        expected.extend([1, 2, 3, 4].repeat(128));
        expected.extend(vec![0; 512]);
        (path, expected)
    }
    #[test]
    fn sparse_reads_and_seeks_match_expanded_image_without_expanding_file() {
        let (path, expected) = fixture();
        let mut source = ImageSource::sparse(File::open(&path).unwrap(), 1536).unwrap();
        assert_eq!(source.size(), 1536);
        assert!(std::fs::metadata(&path).unwrap().len() < 600);
        let mut actual = Vec::new();
        source.read_to_end(&mut actual).unwrap();
        assert_eq!(actual, expected);
        source.seek(SeekFrom::Start(509)).unwrap();
        let mut crossing = [0; 520];
        source.read_exact(&mut crossing).unwrap();
        assert_eq!(&crossing[..], &expected[509..1029]);
        source.seek(SeekFrom::End(-3)).unwrap();
        let mut tail = [1; 3];
        source.read_exact(&mut tail).unwrap();
        assert_eq!(tail, [0; 3]);
        assert!(source.seek(SeekFrom::Start(1537)).is_err());
        drop(source);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn refuses_oversized_or_truncated_sparse_data() {
        let (path, _) = fixture();
        assert!(ImageSource::sparse(File::open(&path).unwrap(), 512).is_err());
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(100)
            .unwrap();
        assert!(ImageSource::sparse(File::open(&path).unwrap(), 1536).is_err());
        std::fs::remove_file(path).unwrap();
    }
}
