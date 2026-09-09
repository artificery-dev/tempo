//! Offline Y2 scatter import. Only USER partitions are imported; no USB access.
use std::{
    collections::BTreeMap,
    fs::File,
    io::Read,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{
    Result, firmware,
    package::{PreparedPackage, create_private_directory},
};

struct Source {
    root: PathBuf,
    archive: Option<zip::ZipArchive<File>>,
    prefix: String,
    scatter: String,
}
impl Source {
    fn open(path: &Path) -> Result<Self> {
        if path
            .extension()
            .is_some_and(|x| x.eq_ignore_ascii_case("zip"))
        {
            let mut archive = zip::ZipArchive::new(File::open(path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
            let names: Vec<_> = archive
                .file_names()
                .filter(|n| n.to_lowercase().ends_with("scatter.txt"))
                .map(str::to_owned)
                .collect();
            if names.len() != 1 {
                return Err("Select a ROM with exactly one scatter file.".into());
            }
            let name = &names[0];
            let mut scatter = String::new();
            archive
                .by_name(name)
                .map_err(|e| e.to_string())?
                .take(256 * 1024)
                .read_to_string(&mut scatter)
                .map_err(|e| e.to_string())?;
            Ok(Self {
                root: path.to_path_buf(),
                archive: Some(archive),
                prefix: name
                    .rsplit_once('/')
                    .map_or(String::new(), |(p, _)| format!("{p}/")),
                scatter,
            })
        } else {
            let scatter_path = if path.is_dir() {
                let paths: Vec<_> = std::fs::read_dir(path)
                    .map_err(|e| e.to_string())?
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| {
                        p.file_name().is_some_and(|n| {
                            n.to_string_lossy().to_lowercase().ends_with("scatter.txt")
                        })
                    })
                    .collect();
                if paths.len() != 1 {
                    return Err("Select a folder with exactly one scatter file.".into());
                }
                paths[0].clone()
            } else {
                path.to_path_buf()
            };
            let scatter = std::fs::read_to_string(&scatter_path).map_err(|e| e.to_string())?;
            if scatter.len() > 256 * 1024 {
                return Err("Scatter file too large".into());
            }
            Ok(Self {
                root: scatter_path
                    .parent()
                    .ok_or("Missing ROM folder")?
                    .to_path_buf(),
                archive: None,
                prefix: String::new(),
                scatter,
            })
        }
    }
    fn size(&mut self, name: &str) -> Result<u64> {
        if let Some(archive) = &mut self.archive {
            Ok(archive
                .by_name(&format!("{}{name}", self.prefix))
                .map_err(|e| e.to_string())?
                .size())
        } else {
            Ok(std::fs::metadata(self.root.join(name))
                .map_err(|e| e.to_string())?
                .len())
        }
    }
    fn read<T>(
        &mut self,
        name: &str,
        action: impl FnOnce(&mut dyn Read) -> Result<T>,
    ) -> Result<T> {
        if name.is_empty() || name.contains(['/', '\\', ':']) || name == "." || name == ".." {
            return Err("Unsafe scatter image filename".into());
        }
        if let Some(archive) = &mut self.archive {
            let mut entry = archive
                .by_name(&format!("{}{name}", self.prefix))
                .map_err(|e| e.to_string())?;
            if entry.is_symlink() || entry.is_dir() || entry.encrypted() {
                return Err("Unsupported ROM archive entry".into());
            }
            action(&mut entry)
        } else {
            let path = self
                .root
                .join(name)
                .canonicalize()
                .map_err(|e| e.to_string())?;
            if path.parent()
                != Some(
                    self.root
                        .canonicalize()
                        .map_err(|e| e.to_string())?
                        .as_path(),
                )
            {
                return Err("ROM image leaves its folder".into());
            }
            action(&mut File::open(path).map_err(|e| e.to_string())?)
        }
    }
}
fn rows(text: &str) -> Result<Vec<BTreeMap<String, String>>> {
    if !text.lines().any(|l| l.trim() == "platform: MT6582")
        || !text
            .lines()
            .any(|l| l.trim() == "project: eastaeon82_wet_kk")
    {
        return Err("Only Innioasis Y2 MT6582 scatter ROMs are supported.".into());
    }
    crate::partitions::scatter(text)?;
    let mut rows = Vec::<BTreeMap<String, String>>::new();
    for line in text.lines().map(str::trim) {
        if line.starts_with("- partition_index:") {
            rows.push(BTreeMap::new());
        }
        if let Some((k, v)) = line.split_once(':')
            && let Some(row) = rows.last_mut()
        {
            row.insert(k.trim().into(), v.trim().into());
        }
    }
    Ok(rows)
}
fn get<'a>(r: &'a BTreeMap<String, String>, k: &str) -> Result<&'a str> {
    r.get(k)
        .map(String::as_str)
        .ok_or_else(|| format!("Missing scatter {k}"))
}
fn number(r: &BTreeMap<String, String>, k: &str) -> Result<u64> {
    let s = get(r, k)?;
    if let Some(h) = s.strip_prefix("0x") {
        u64::from_str_radix(h, 16)
    } else {
        s.parse()
    }
    .map_err(|_| format!("Invalid scatter {k}"))
}
fn word(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn half(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(b[at..at + 2].try_into().unwrap())
}
fn exact(r: &mut dyn Read, b: &mut [u8]) -> Result<()> {
    r.read_exact(b).map_err(|e| e.to_string())
}

pub fn preview(path: &Path) -> Result<Value> {
    let mut source = Source::open(path)?;
    let rows = rows(&source.scatter)?;
    let name = path
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let mut info = json!({"event":"firmware-info","firmware":{"name":name,"version":"Not specified","format":"Legacy SPFT ROM"},"includes_preloader":false,"legacy":true});
    if let Some(logo) = rows
        .iter()
        .find(|r| r.get("partition_name").is_some_and(|s| s == "LOGO"))
    {
        let pixels = source.read(get(logo, "file_name")?, |r| {
            let mut bytes = Vec::new();
            r.take(0x300001)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            crate::raw_image::inspect(crate::raw_image::Target::Logo, &bytes)?;
            let start = 512 + word(&bytes, 520) as usize;
            let end = 512
                + if word(&bytes, 512) > 1 {
                    word(&bytes, 524)
                } else {
                    word(&bytes, 516)
                } as usize;
            let mut raw = Vec::new();
            flate2::read::ZlibDecoder::new(&bytes[start..end])
                .take(480 * 360 * 2 + 1)
                .read_to_end(&mut raw)
                .map_err(|e| e.to_string())?;
            if raw.len() != 480 * 360 * 2 {
                return Err("LOGO first image is not 480×360 RGB565".into());
            }
            let mut hex = String::new();
            for y in 0..90 {
                for x in 0..120 {
                    let i = (y * 4 * 480 + x * 4) * 2;
                    let v = half(&raw, i);
                    hex.push_str(&format!(
                        "{:02x}{:02x}{:02x}ff",
                        ((v >> 11) & 31) * 255 / 31,
                        ((v >> 5) & 63) * 255 / 63,
                        (v & 31) * 255 / 31
                    ));
                }
            }
            Ok(hex)
        });
        match pixels {
            Ok(p) => info["logo_rgba"] = json!(p),
            Err(e) => info["preview_warning"] = json!(e),
        }
    }
    Ok(info)
}

/// Expand Android sparse chunks with bounded output. DONT_CARE becomes zeroes.
#[cfg(test)]
fn expand(
    r: &mut dyn Read,
    limit: u64,
    mut output: impl FnMut(&[u8]) -> Result<()>,
) -> Result<u64> {
    let mut header = [0u8; 28];
    exact(r, &mut header[..4])?;
    let mut written = 0u64;
    let mut emit = |bytes: &[u8]| -> Result<()> {
        written = written
            .checked_add(bytes.len() as u64)
            .ok_or("Image size overflow")?;
        if written > limit {
            return Err("Image exceeds scatter partition".into());
        }
        output(bytes)
    };
    if word(&header, 0) != 0xed26ff3a {
        emit(&header[..4])?;
        let mut b = vec![0; 1024 * 1024];
        loop {
            let n = r.read(&mut b).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            emit(&b[..n])?;
        }
    } else {
        exact(r, &mut header[4..])?;
        if word(&header, 24) != 0
            || half(&header, 4) != 1
            || half(&header, 8) != 28
            || half(&header, 10) != 12
            || word(&header, 12) == 0
            || !word(&header, 12).is_multiple_of(512)
        {
            return Err("Unsupported Android sparse header".into());
        }
        let expected = (word(&header, 12) as u64)
            .checked_mul(word(&header, 16) as u64)
            .ok_or("Sparse size overflow")?;
        if expected > limit || word(&header, 20) > 1_000_000 {
            return Err("Sparse image exceeds limits".into());
        }
        let mut b = vec![0u8; 1024 * 1024];
        for _ in 0..word(&header, 20) {
            let mut c = [0u8; 12];
            exact(r, &mut c)?;
            let len = (word(&c, 4) as u64)
                .checked_mul(word(&header, 12) as u64)
                .ok_or("Sparse chunk overflow")?;
            let payload = word(&c, 8) as u64;
            match half(&c, 0) {
                0xcac1 if payload == 12 + len => {
                    let mut left = len;
                    while left > 0 {
                        let n = left.min(b.len() as u64) as usize;
                        exact(r, &mut b[..n])?;
                        emit(&b[..n])?;
                        left -= n as u64;
                    }
                }
                0xcac2 if payload == 16 => {
                    let mut fill = [0; 4];
                    exact(r, &mut fill)?;
                    for c in b.as_chunks_mut::<4>().0 {
                        c.copy_from_slice(&fill);
                    }
                    let mut left = len;
                    while left > 0 {
                        let n = left.min(b.len() as u64) as usize;
                        emit(&b[..n])?;
                        left -= n as u64;
                    }
                }
                0xcac3 if payload == 12 => {
                    b.fill(0);
                    let mut left = len;
                    while left > 0 {
                        let n = left.min(b.len() as u64) as usize;
                        emit(&b[..n])?;
                        left -= n as u64;
                    }
                }
                _ => return Err("Unsupported or malformed Android sparse chunk".into()),
            }
        }
        if written != expected {
            return Err("Sparse image block count mismatch".into());
        }
        let mut extra = [0];
        if r.read(&mut extra).map_err(|e| e.to_string())? != 0 {
            return Err("Trailing sparse data".into());
        }
    }
    Ok(written)
}

pub fn prepare_in(
    path: &Path,
    staging_root: &Path,
    mut progress: impl FnMut(u64, u64),
) -> Result<PreparedPackage> {
    let mut source = Source::open(path)?;
    let rows = rows(&source.scatter)?;
    let root = staging_root.join(format!(
        "tempo-y2-firmware-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos()
    ));
    create_private_directory(&root)?;
    let manifest = firmware::Manifest {
        format: firmware::FORMAT.into(),
        format_version: 1,
        device: firmware::Device {
            id: "innioasis-y2".into(),
            hardware_code: 0x6582,
            hardware_subcode: 0x8a00,
            storage: firmware::Storage {
                boot1: 0x400000,
                boot2: 0x400000,
                user: 0x1d2000000,
            },
        },
        firmware: firmware::Firmware {
            id: "legacy-spft".into(),
            name: path
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
            version: "Not specified".into(),
            commit: None,
            icon: None,
        },
        images: Vec::new(),
    };
    let mut package = PreparedPackage {
        manifest,
        root,
        files: Vec::new(),
        cleanup: true,
    };
    let selected: Vec<_> = rows
        .iter()
        .filter(|r| {
            r.get("is_download").is_some_and(|s| s == "true")
                && r.get("region").is_some_and(|s| s == "EMMC_USER")
        })
        .collect();
    let mut sizes = Vec::new();
    for row in &selected {
        let name = get(row, "file_name")?;
        let sparse_size = source.read(name, |r| {
            let mut header = [0u8; 28];
            exact(r, &mut header[..4])?;
            if word(&header, 0) == 0xed26ff3a {
                exact(r, &mut header[4..])?;
                Ok(Some(word(&header, 12) as u64 * word(&header, 16) as u64))
            } else {
                Ok(None)
            }
        })?;
        let size = sparse_size.unwrap_or(source.size(name)?);
        if size == 0 || size > number(row, "partition_size")? || size > 0x1d2000000 {
            return Err("Invalid ROM image size".into());
        }
        sizes.push(size.div_ceil(512) * 512);
    }
    let total = sizes
        .iter()
        .try_fold(0u64, |a, b| a.checked_add(*b).ok_or("ROM size overflow"))?;
    let mut completed = 0;
    progress(0, total);
    for (index, row) in selected.iter().enumerate() {
        let name = get(row, "file_name")?;
        let capacity = number(row, "partition_size")?;
        let start = number(row, "physical_start_addr")?
            .checked_add(0xb80000)
            .ok_or("Address overflow")?;
        if capacity == 0 || start.checked_add(capacity).is_none_or(|e| e > 0x1d2000000) {
            return Err("Scatter partition outside Y2 USER region".into());
        }
        let input_size = source.size(name)?;
        if input_size > capacity.saturating_add(64 * 1024 * 1024) {
            return Err("ROM input exceeds partition limits".into());
        }
        let sparse = source.read(name, |r| {
            let mut magic = [0; 4];
            exact(r, &mut magic)?;
            Ok(u32::from_le_bytes(magic) == 0xed26ff3a)
        })?;
        let staged = package.root.join(format!(
            "image-{index}.{}",
            if sparse { "sparse" } else { "bin" }
        ));
        let mut output = File::options()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&staged)
            .map_err(|e| e.to_string())?;
        source.read(name, |r| {
            let copied = std::io::copy(&mut r.take(input_size + 1), &mut output)
                .map_err(|e| e.to_string())?;
            if copied != input_size {
                return Err("ROM input size changed".into());
            }
            Ok(())
        })?;
        let mut file = if sparse {
            crate::sparse_image::ImageSource::sparse(output, capacity)?
        } else {
            output
                .set_len(input_size.div_ceil(512) * 512)
                .map_err(|e| e.to_string())?;
            crate::sparse_image::ImageSource::raw(output)?
        };
        use std::io::{Seek, SeekFrom};
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        let padded = file.size();
        if padded != sizes[index] {
            return Err("ROM image size changed".into());
        }
        let mut hash = Sha256::new();
        let mut buffer = vec![0; 1024 * 1024];
        loop {
            let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
            completed += count as u64;
            progress(completed, total);
        }
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        package.manifest.images.push(firmware::Image {
            file: format!("images/image-{index}.bin"),
            size: padded,
            sha256: hash.finalize().iter().map(|b| format!("{b:02x}")).collect(),
            writes: vec![firmware::Write {
                name: get(row, "partition_name")?.into(),
                region: firmware::Region::User,
                source_offset: 0,
                target_offset: start,
                length: padded,
            }],
        });
        package.files.push(file);
        progress(completed, total);
    }
    package.manifest.validate()?;
    Ok(package)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sparse() -> Vec<u8> {
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
        b
    }
    #[test]
    fn expands_sparse_raw_fill_and_holes() {
        let mut out = Vec::<u8>::new();
        assert_eq!(
            expand(&mut sparse().as_slice(), 1536, |b| {
                out.extend(b);
                Ok(())
            })
            .unwrap(),
            1536
        );
        assert_eq!(&out[..512], vec![7; 512]);
        assert_eq!(&out[512..1024], [1, 2, 3, 4].repeat(128));
        assert_eq!(&out[1024..], vec![0; 512]);
    }
    #[test]
    fn rejects_oversized_truncated_and_trailing_sparse_images() {
        assert!(expand(&mut sparse().as_slice(), 512, |_| Ok(())).is_err());
        let mut b = sparse();
        b.pop();
        assert!(expand(&mut b.as_slice(), 1536, |_| Ok(())).is_err());
        let mut b = sparse();
        b.push(0);
        assert!(expand(&mut b.as_slice(), 1536, |_| Ok(())).is_err());
    }
    #[test]
    fn rejects_other_boards_and_path_traversal() {
        assert!(rows("platform: MT1234").is_err());
        let mut source = Source {
            root: PathBuf::new(),
            archive: None,
            prefix: String::new(),
            scatter: String::new(),
        };
        assert!(source.read("../boot.img", |_| Ok(())).is_err());
        assert!(source.read("C:\\boot.img", |_| Ok(())).is_err());
    }
    #[test]
    fn previews_stock_logo_before_import() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../platform/firmware/stock/MT6582_Android_scatter.txt");
        let info = preview(&path).unwrap();
        assert_eq!(info["logo_rgba"].as_str().unwrap().len(), 120 * 90 * 8);
        assert_eq!(info["includes_preloader"], false);
    }
}
