//! Strict native reader and temporary staging for `.y2-firmware` archives.

use std::{
    collections::HashSet,
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use sha2::{Digest, Sha256};
use zip::{CompressionMethod, ZipArchive};

use crate::{Result, firmware, sparse_image::ImageSource};

#[derive(Debug)]
pub struct PackageInfo {
    pub manifest: firmware::Manifest,
}

fn open(path: &Path) -> Result<ZipArchive<File>> {
    let file = File::open(path).map_err(|e| format!("Cannot open firmware package: {e}"))?;
    let mut archive =
        ZipArchive::new(file).map_err(|e| format!("Invalid firmware archive: {e}"))?;
    if archive.offset() != 0 {
        return Err("Firmware archive has unexpected bytes before its ZIP header".into());
    }
    if archive
        .has_overlapping_files()
        .map_err(|e| format!("Invalid firmware archive: {e}"))?
    {
        return Err("Firmware archive contains overlapping entries".into());
    }
    Ok(archive)
}

fn check_entry<R: Read>(file: &zip::read::ZipFile<'_, R>) -> Result<()> {
    if file.encrypted() {
        return Err(format!(
            "Encrypted archive entry {} is not supported",
            file.name()
        ));
    }
    if file.is_dir() || file.is_symlink() || file.enclosed_name().is_none() {
        return Err(format!("Unsafe archive entry {}", file.name()));
    }
    if file.name_raw() != file.name().as_bytes() {
        return Err(format!(
            "Archive entry {} does not have a UTF-8 name",
            file.name()
        ));
    }
    if !matches!(
        file.compression(),
        CompressionMethod::Stored | CompressionMethod::Deflated
    ) {
        return Err(format!(
            "Archive entry {} uses unsupported compression {}",
            file.name(),
            file.compression()
        ));
    }
    Ok(())
}

pub fn inspect(path: &Path) -> Result<PackageInfo> {
    if path.is_dir() {
        let bytes =
            std::fs::read(path.join("prepared-manifest.json")).map_err(|e| e.to_string())?;
        return Ok(PackageInfo {
            manifest: firmware::Manifest::parse(&bytes)?,
        });
    }
    let mut archive = open(path)?;
    if archive.is_empty() {
        return Err("Firmware archive is empty".into());
    }
    if archive.len() > 257 {
        return Err("Firmware archive contains too many entries".into());
    }
    let manifest_bytes = {
        let mut entry = archive
            .by_index(0)
            .map_err(|e| format!("Cannot read firmware manifest: {e}"))?;
        check_entry(&entry)?;
        if entry.name() != "manifest.json" {
            return Err("manifest.json must be the first archive entry".into());
        }
        if entry.size() > 1024 * 1024 {
            return Err("Firmware manifest is larger than 1 MiB".into());
        }
        let mut bytes = Vec::with_capacity(entry.size() as usize);
        entry
            .by_ref()
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| format!("Cannot read firmware manifest: {e}"))?;
        if bytes.len() as u64 != entry.size() {
            return Err("Firmware manifest size does not match its ZIP entry".into());
        }
        bytes
    };
    let manifest = firmware::Manifest::parse(&manifest_bytes)?;
    let expected: HashSet<_> = manifest
        .images
        .iter()
        .map(|image| image.file.as_str())
        .collect();
    let mut found = HashSet::new();
    for index in 1..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|e| format!("Cannot inspect archive entry: {e}"))?;
        check_entry(&entry)?;
        if !expected.contains(entry.name()) {
            return Err(format!("Unreferenced archive entry {}", entry.name()));
        }
        if !found.insert(entry.name().to_owned()) {
            return Err(format!("Duplicate archive entry {}", entry.name()));
        }
        let image = manifest
            .images
            .iter()
            .find(|image| image.file == entry.name())
            .expect("checked name set");
        if entry.size() != image.size {
            return Err(format!("Size mismatch for {}", entry.name()));
        }
    }
    if found.len() != expected.len() {
        return Err("Firmware archive is missing a referenced image".into());
    }
    Ok(PackageInfo { manifest })
}

pub(crate) fn create_private_directory(root: &Path) -> Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(root)
        .map_err(|e| format!("Cannot create private staging directory: {e}"))
}

pub struct PreparedPackage {
    pub manifest: firmware::Manifest,
    pub(crate) root: PathBuf,
    pub(crate) files: Vec<ImageSource>,
    pub(crate) cleanup: bool,
}

impl PreparedPackage {
    /// Retain validated images for the UI workflow; the caller owns cleanup.
    pub fn retain(&mut self) -> Result<PathBuf> {
        std::fs::write(
            self.root.join("prepared-manifest.json"),
            serde_json::to_vec(&self.manifest).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        self.cleanup = false;
        Ok(self.root.clone())
    }

    /// Decompress and hash every image before the device is opened.
    pub fn prepare(path: &Path, progress: impl FnMut(u64, u64)) -> Result<Self> {
        Self::prepare_in(path, &std::env::temp_dir(), progress)
    }
    pub fn prepare_in(
        path: &Path,
        staging_root: &Path,
        mut progress: impl FnMut(u64, u64),
    ) -> Result<Self> {
        let info = inspect(path)?;
        if path.is_dir() {
            let total = info.manifest.images.iter().map(|i| i.size).sum();
            let mut completed = 0;
            let mut files = Vec::new();
            for (index, image) in info.manifest.images.iter().enumerate() {
                let sparse = path.join(format!("image-{index}.sparse"));
                let mut file = if sparse.exists() {
                    ImageSource::sparse(File::open(sparse).map_err(|e| e.to_string())?, image.size)?
                } else {
                    ImageSource::raw(
                        File::open(path.join(format!("image-{index}.bin")))
                            .map_err(|e| e.to_string())?,
                    )?
                };
                if file.size() != image.size {
                    return Err(format!("Size mismatch for {}", image.file));
                }
                let mut hasher = Sha256::new();
                let mut buffer = vec![0; 1024 * 1024];
                loop {
                    let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
                    if count == 0 {
                        break;
                    }
                    hasher.update(&buffer[..count]);
                    completed += count as u64;
                    progress(completed, total);
                }
                if hasher
                    .finalize()
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
                    != image.sha256
                {
                    return Err(format!("SHA-256 mismatch for {}", image.file));
                }
                file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
                files.push(file);
            }
            return Ok(Self {
                manifest: info.manifest,
                root: path.to_path_buf(),
                files,
                cleanup: false,
            });
        }
        let total = info.manifest.images.iter().try_fold(0u64, |sum, image| {
            sum.checked_add(image.size).ok_or("Firmware size overflow")
        })?;
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos();
        let root = staging_root.join(format!("tempo-y2-firmware-{}-{unique}", std::process::id()));
        create_private_directory(&root)?;
        let prepared = (|| -> Result<Vec<ImageSource>> {
            let mut archive = open(path)?;
            let mut completed = 0u64;
            let mut files = Vec::with_capacity(info.manifest.images.len());
            for (index, image) in info.manifest.images.iter().enumerate() {
                let mut entry = archive
                    .by_name(&image.file)
                    .map_err(|e| format!("Cannot read {}: {e}", image.file))?;
                check_entry(&entry)?;
                let staged_path = root.join(format!("image-{index}.bin"));
                let mut output = File::options()
                    .read(true)
                    .write(true)
                    .create_new(true)
                    .open(&staged_path)
                    .map_err(|e| format!("Cannot stage {}: {e}", image.file))?;
                let mut hasher = Sha256::new();
                let mut written = 0u64;
                let mut buffer = vec![0u8; 1024 * 1024];
                loop {
                    let count = entry
                        .read(&mut buffer)
                        .map_err(|e| format!("Cannot decompress {}: {e}", image.file))?;
                    if count == 0 {
                        break;
                    }
                    written = written
                        .checked_add(count as u64)
                        .ok_or("Firmware size overflow")?;
                    if written > image.size {
                        return Err(format!("{} expands beyond its declared size", image.file));
                    }
                    if buffer[..count].iter().all(|b| *b == 0) {
                        output
                            .seek(SeekFrom::Current(count as i64))
                            .map_err(|e| e.to_string())?;
                    } else {
                        output
                            .write_all(&buffer[..count])
                            .map_err(|e| format!("Cannot stage {}: {e}", image.file))?;
                    }
                    hasher.update(&buffer[..count]);
                    completed += count as u64;
                    progress(completed, total);
                }
                if written != image.size {
                    return Err(format!("Size mismatch for {}", image.file));
                }
                let digest = hasher.finalize();
                let actual = digest
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>();
                if actual != image.sha256 {
                    return Err(format!("SHA-256 mismatch for {}", image.file));
                }
                output.set_len(written).map_err(|e| e.to_string())?;
                output.sync_all().map_err(|e| e.to_string())?;
                output.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
                files.push(ImageSource::raw(output)?);
            }
            Ok(files)
        })();
        match prepared {
            Ok(files) => Ok(Self {
                manifest: info.manifest,
                root,
                files,
                cleanup: true,
            }),
            Err(error) => {
                let _ = std::fs::remove_dir_all(&root);
                Err(error)
            }
        }
    }
}

impl firmware::FirmwareSource for PreparedPackage {
    async fn chunk(&mut self, image: usize, offset: u64, length: usize) -> Result<Vec<u8>> {
        let file = self.files.get_mut(image).ok_or("Unknown firmware image")?;
        file.seek(SeekFrom::Start(offset))
            .map_err(|e| e.to_string())?;
        let mut bytes = vec![0; length];
        file.read_exact(&mut bytes).map_err(|e| e.to_string())?;
        Ok(bytes)
    }
}

impl Drop for PreparedPackage {
    fn drop(&mut self) {
        self.files.clear();
        if self.cleanup {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;

    use zip::write::SimpleFileOptions;

    use super::*;
    use crate::firmware::{
        Device, Firmware, FirmwareSource, Image, Region, Storage, Write, Y2_BOOT_SIZE, Y2_USER_SIZE,
    };

    fn fixture(extra: bool) -> (PathBuf, Vec<u8>) {
        let bytes: Vec<_> = (0..512).map(|value| value as u8).collect();
        let sha256 = Sha256::digest(&bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let manifest = firmware::Manifest {
            format: firmware::FORMAT.into(),
            format_version: firmware::FORMAT_VERSION,
            device: Device {
                id: "innioasis-y2".into(),
                hardware_code: 0x6582,
                hardware_subcode: 0x8a00,
                storage: Storage {
                    boot1: Y2_BOOT_SIZE,
                    boot2: Y2_BOOT_SIZE,
                    user: Y2_USER_SIZE,
                },
            },
            firmware: Firmware {
                icon: None,
                commit: None,
                id: "fixture".into(),
                name: "Fixture".into(),
                version: "1".into(),
            },
            images: vec![Image {
                file: "images/system.bin".into(),
                size: 512,
                sha256,
                writes: vec![Write {
                    name: "system".into(),
                    region: Region::User,
                    source_offset: 0,
                    target_offset: 0,
                    length: 512,
                }],
            }],
        };
        let path = std::env::temp_dir().join(format!(
            "tempo-package-test-{}-{}.y2-firmware",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let file = File::create(&path).unwrap();
        let mut archive = zip::ZipWriter::new(file);
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .large_file(true);
        archive.start_file("manifest.json", options).unwrap();
        archive
            .write_all(&serde_json::to_vec(&manifest).unwrap())
            .unwrap();
        archive.start_file("images/system.bin", options).unwrap();
        archive.write_all(&bytes).unwrap();
        if extra {
            archive
                .start_file("images/unreferenced.bin", options)
                .unwrap();
            archive.write_all(&[0]).unwrap();
        }
        archive.finish().unwrap();
        (path, bytes)
    }

    #[test]
    fn inspects_stages_hashes_and_cleans_up_a_package() {
        let (path, expected) = fixture(false);
        let info = inspect(&path).unwrap();
        assert_eq!(info.manifest.firmware.name, "Fixture");
        let mut progress = vec![];
        let mut package = PreparedPackage::prepare(&path, |done, total| {
            progress.push((done, total));
        })
        .unwrap();
        let root = package.root.clone();
        assert_eq!(
            pollster::block_on(package.chunk(0, 0, 512)).unwrap(),
            expected
        );
        assert_eq!(progress.last(), Some(&(512, 512)));
        drop(package);
        assert!(!root.exists());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn retained_images_survive_reopen_and_reject_tampering() {
        let (path, expected) = fixture(false);
        let mut package = PreparedPackage::prepare(&path, |_, _| {}).unwrap();
        let root = package.retain().unwrap();
        drop(package);
        std::fs::remove_file(path).unwrap();
        let mut reopened = PreparedPackage::prepare(&root, |_, _| {}).unwrap();
        assert_eq!(
            pollster::block_on(reopened.chunk(0, 0, 512)).unwrap(),
            expected
        );
        drop(reopened);
        assert!(root.exists());
        std::fs::write(root.join("image-0.bin"), vec![0x77; 512]).unwrap();
        assert!(
            PreparedPackage::prepare(&root, |_, _| {})
                .err()
                .unwrap()
                .contains("SHA-256")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_unreferenced_archive_entries() {
        let (path, _) = fixture(true);
        assert!(inspect(&path).unwrap_err().contains("Unreferenced"));
        std::fs::remove_file(path).unwrap();
    }
}
