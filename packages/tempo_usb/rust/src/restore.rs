//! Backup import is staging only: all USB writes use firmware::flash_verified.
//! Gzip continuous DA images contain an RPMB interval which is never restored.
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use sha2::{Digest, Sha256};

use crate::{
    Result,
    firmware::{
        self, Device, Firmware, Image, Manifest, Region, Storage, Y2_BOOT_SIZE, Y2_USER_SIZE,
    },
    package::PreparedPackage,
};

pub const RPMB_SIZE: u64 = 0x80000;
pub const CONTINUOUS_SIZE: u64 = Y2_BOOT_SIZE * 2 + RPMB_SIZE + Y2_USER_SIZE;

fn stage(
    reader: &mut dyn Read,
    output: &mut File,
    size: u64,
    completed: &mut u64,
    cancelled: &AtomicBool,
    progress: &mut impl FnMut(u64, u64),
) -> Result<String> {
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    let mut remaining = size;
    while remaining > 0 {
        if cancelled.load(Ordering::Relaxed) {
            return Err("Restore preparation cancelled".into());
        }
        let count = remaining.min(buffer.len() as u64) as usize;
        reader
            .read_exact(&mut buffer[..count])
            .map_err(|e| format!("Backup is truncated or corrupt: {e}"))?;
        output
            .write_all(&buffer[..count])
            .map_err(|e| format!("Cannot stage backup (8 GB free space required): {e}"))?;
        hash.update(&buffer[..count]);
        remaining -= count as u64;
        *completed += count as u64;
        progress(*completed, Y2_BOOT_SIZE * 2 + Y2_USER_SIZE);
    }
    output.sync_all().map_err(|e| e.to_string())?;
    output.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}
fn end(reader: &mut dyn Read) -> Result<()> {
    let mut extra = [0];
    if reader
        .read(&mut extra)
        .map_err(|e| format!("Backup checksum/trailer failed: {e}"))?
        != 0
    {
        return Err("Backup exceeds the verified Y2 geometry".into());
    }
    Ok(())
}
fn manifest(images: Vec<Image>) -> Manifest {
    Manifest {
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
            id: "backup-restore".into(),
            name: "Y2 backup restore".into(),
            version: "1".into(),
        },
        images,
    }
}

fn number(value: &serde_json::Value, key: &str) -> Result<u64> {
    value[key]
        .as_u64()
        .ok_or_else(|| format!("backup.json has invalid {key}"))
}
fn legacy_metadata(path: &Path) -> Result<serde_json::Value> {
    let file = path.join("backup.json");
    if std::fs::metadata(&file)
        .map_err(|e| format!("Legacy backup requires backup.json: {e}"))?
        .len()
        > 16 * 1024 * 1024
    {
        return Err("backup.json exceeds 16 MiB".into());
    }
    let value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(file).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    validate_legacy_metadata(
        &value,
        std::fs::metadata(path.join("emmc-user.img.zst"))
            .map_err(|e| e.to_string())?
            .len(),
    )?;
    Ok(value)
}
fn validate_legacy_metadata(value: &serde_json::Value, compressed_size: u64) -> Result<()> {
    validate_legacy_prefix(value, compressed_size, true)
}
pub(crate) fn validate_legacy_prefix(
    value: &serde_json::Value,
    compressed_size: u64,
    complete: bool,
) -> Result<()> {
    if value["format"] != "tempo-mtk-emmc-1" || (complete && value["complete"] != true) {
        return Err("Legacy backup is incomplete or has an unsupported format".into());
    }
    for (key, expected) in [
        ("hwcode", 0x6582),
        ("emmc_user_size", Y2_USER_SIZE),
        ("emmc_boot1_size", Y2_BOOT_SIZE),
        ("emmc_boot2_size", Y2_BOOT_SIZE),
    ] {
        if number(&value["device"], key)? != expected {
            return Err(format!("Legacy backup {key} does not match Y2"));
        }
    }
    for (key, file, size) in [
        ("boot1", "boot1.img", Y2_BOOT_SIZE),
        ("boot2", "boot2.img", Y2_BOOT_SIZE),
        ("user", "emmc-user.img.zst", Y2_USER_SIZE),
    ] {
        if value[key]["file"] != file || number(&value[key], "size")? != size {
            return Err(format!("Legacy backup has invalid {key} file/geometry"));
        }
    }
    let user = &value["user"];
    let chunk = number(user, "chunk")?;
    if chunk == 0 || !chunk.is_multiple_of(512) {
        return Err("Invalid legacy chunk size".into());
    }
    let chunks = user["chunks"].as_array().ok_or("Missing legacy chunks")?;
    if chunks.len() > 65536 {
        return Err("Too many legacy chunks".into());
    }
    let (mut offset, mut frame) = (0u64, 0u64);
    for (index, part) in chunks.iter().enumerate() {
        if offset >= Y2_USER_SIZE
            || number(part, "index")? != index as u64
            || number(part, "offset")? != offset
            || number(part, "frame_offset")? != frame
            || number(part, "length")? != chunk.min(Y2_USER_SIZE - offset)
            || number(part, "frame_size")? == 0
        {
            return Err("Legacy backup chunks are not contiguous and complete".into());
        }
        offset += number(part, "length")?;
        frame = frame
            .checked_add(number(part, "frame_size")?)
            .ok_or("Legacy frame size overflow")?;
        if part["sha256"]
            .as_str()
            .is_none_or(|s| s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()))
        {
            return Err("Invalid legacy chunk SHA-256".into());
        }
    }
    if (complete && (offset != Y2_USER_SIZE || frame != compressed_size)) || frame > compressed_size
    {
        return Err("Legacy backup does not cover the complete USER image".into());
    }
    Ok(())
}
fn verify_legacy_hashes(
    file: &mut File,
    region: Region,
    hash: &str,
    metadata: &serde_json::Value,
    cancelled: &AtomicBool,
) -> Result<()> {
    if region != Region::User {
        let name = if region == Region::Boot1 {
            "boot1"
        } else {
            "boot2"
        };
        if metadata[name]["sha256"].as_str() != Some(hash) {
            return Err(format!("{name} SHA-256 does not match backup.json"));
        }
        return Ok(());
    }
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let mut buffer = vec![0u8; 1024 * 1024];
    for part in metadata["user"]["chunks"]
        .as_array()
        .ok_or("Missing chunks")?
    {
        let mut remaining = number(part, "length")?;
        let mut hasher = Sha256::new();
        while remaining > 0 {
            if cancelled.load(Ordering::Relaxed) {
                return Err("Restore validation cancelled".into());
            }
            let count = remaining.min(buffer.len() as u64) as usize;
            file.read_exact(&mut buffer[..count])
                .map_err(|e| e.to_string())?;
            hasher.update(&buffer[..count]);
            remaining -= count as u64;
        }
        let actual: String = hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        if part["sha256"].as_str() != Some(&actual) {
            return Err(format!(
                "USER chunk {} SHA-256 does not match backup.json",
                part["index"]
            ));
        }
    }
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    Ok(())
}

/// Accept either a complete installer gzip image or a legacy mtkclient folder
/// containing boot1.img, boot2.img and emmc-user.img.zst. Never infer offsets
/// from filenames: every output is anchored to one explicit hardware region.
pub fn prepare(
    path: &Path,
    cancelled: &AtomicBool,
    mut progress: impl FnMut(u64, u64),
) -> Result<PreparedPackage> {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("tempo-y2-restore-{}-{unique}", std::process::id()));
    crate::package::create_private_directory(&root)?;
    let mut package = PreparedPackage {
        manifest: manifest(Vec::new()),
        root,
        files: Vec::new(),
        cleanup: true,
    };
    let legacy = path.is_dir();
    let metadata = if legacy {
        Some(legacy_metadata(path)?)
    } else {
        None
    };
    let mut continuous: Option<Box<dyn Read>> = if legacy {
        None
    } else {
        let mut file = File::open(path).map_err(|e| format!("Cannot open backup: {e}"))?;
        let mut magic = [0; 2];
        file.read_exact(&mut magic).map_err(|e| e.to_string())?;
        if magic != [0x1f, 0x8b] {
            return Err("Expected a gzip continuous backup or legacy backup directory".into());
        }
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        Some(Box::new(flate2::read::MultiGzDecoder::new(file)))
    };
    let mut completed = 0;
    for (index, (region, name, size)) in [
        (Region::Boot1, "boot1.img", Y2_BOOT_SIZE),
        (Region::Boot2, "boot2.img", Y2_BOOT_SIZE),
        (Region::User, "emmc-user.img.zst", Y2_USER_SIZE),
    ]
    .into_iter()
    .enumerate()
    {
        let mut output = File::options()
            .read(true)
            .write(true)
            .create_new(true)
            .open(package.root.join(format!("image-{index}.bin")))
            .map_err(|e| e.to_string())?;
        let hash = if let Some(reader) = continuous.as_mut() {
            if region == Region::User {
                // RPMB is authenticated hardware state. Consume, never map it.
                let mut discard = vec![0; RPMB_SIZE as usize];
                reader
                    .read_exact(&mut discard)
                    .map_err(|e| format!("Truncated RPMB interval: {e}"))?;
            }
            stage(
                reader,
                &mut output,
                size,
                &mut completed,
                cancelled,
                &mut progress,
            )?
        } else {
            let input = File::open(path.join(name))
                .map_err(|e| format!("Missing legacy backup component {name}: {e}"))?;
            let mut reader: Box<dyn Read> = if region == Region::User {
                Box::new(zstd::stream::read::Decoder::new(input).map_err(|e| e.to_string())?)
            } else {
                Box::new(input)
            };
            let hash = stage(
                &mut reader,
                &mut output,
                size,
                &mut completed,
                cancelled,
                &mut progress,
            )?;
            end(&mut reader)?;
            hash
        };
        if let Some(metadata) = &metadata {
            verify_legacy_hashes(&mut output, region, &hash, metadata, cancelled)?;
        }
        package
            .files
            .push(crate::sparse_image::ImageSource::raw(output)?);
        package.manifest.images.push(Image {
            file: format!("images/{index}.bin"),
            size,
            sha256: hash,
            writes: vec![firmware::Write {
                name: format!("restore-{region:?}"),
                region,
                source_offset: 0,
                target_offset: 0,
                length: size,
            }],
        });
    }
    if let Some(reader) = continuous.as_mut() {
        end(reader)?;
    }
    package.manifest.validate()?;
    Ok(package)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restore_plan_never_maps_rpmb_and_boot1_is_guarded() {
        let images = [
            (Region::Boot1, Y2_BOOT_SIZE),
            (Region::Boot2, Y2_BOOT_SIZE),
            (Region::User, Y2_USER_SIZE),
        ]
        .into_iter()
        .enumerate()
        .map(|(i, (region, size))| Image {
            file: format!("images/{i}.bin"),
            size,
            sha256: "00".repeat(32),
            writes: vec![firmware::Write {
                name: format!("{region:?}"),
                region,
                source_offset: 0,
                target_offset: 0,
                length: size,
            }],
        })
        .collect();
        let manifest = manifest(images);
        let plan = manifest.write_plan(false).unwrap();
        assert_eq!(
            plan.iter().map(|w| w.region).collect::<Vec<_>>(),
            vec![Region::Boot2, Region::User]
        );
        assert!(
            plan.iter()
                .all(|w| w.target_offset == 0 && w.source_offset == 0)
        );
        assert_eq!(manifest.write_plan(true).unwrap().len(), 3);
        assert_eq!(CONTINUOUS_SIZE, 7827095552);
    }
    #[test]
    fn stream_validation_refuses_truncated_excess_and_cancelled_data() {
        let root = std::env::temp_dir().join(format!("tempo-restore-test-{}", std::process::id()));
        let mut file = File::create(&root).unwrap();
        let mut completed = 0;
        assert!(
            stage(
                &mut &b"short"[..],
                &mut file,
                512,
                &mut completed,
                &AtomicBool::new(false),
                &mut |_, _| {}
            )
            .is_err()
        );
        assert!(
            stage(
                &mut &b""[..],
                &mut file,
                512,
                &mut completed,
                &AtomicBool::new(true),
                &mut |_, _| {}
            )
            .is_err()
        );
        assert!(end(&mut &b"extra"[..]).is_err());
        std::fs::remove_file(root).unwrap();
    }
    #[test]
    fn gzip_crc_and_zstd_frames_are_checked_before_device_access() {
        let data = vec![0x5a; 512];
        let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gzip.write_all(&data).unwrap();
        let mut bytes = gzip.finish().unwrap();
        let crc = bytes.len() - 8;
        bytes[crc] ^= 1;
        let mut decoded = Vec::new();
        assert!(
            flate2::read::MultiGzDecoder::new(bytes.as_slice())
                .read_to_end(&mut decoded)
                .is_err()
        );
        let compressed = zstd::stream::encode_all(data.as_slice(), 1).unwrap();
        let mut reader = zstd::stream::read::Decoder::new(compressed.as_slice()).unwrap();
        let root =
            std::env::temp_dir().join(format!("tempo-zstd-stage-test-{}", std::process::id()));
        let mut output = File::options()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&root)
            .unwrap();
        let hash = stage(
            &mut reader,
            &mut output,
            512,
            &mut 0,
            &AtomicBool::new(false),
            &mut |_, _| {},
        )
        .unwrap();
        assert_eq!(
            hash,
            Sha256::digest(&data)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        end(&mut reader).unwrap();
        drop(output);
        std::fs::remove_file(root).unwrap();
    }
    #[test]
    fn legacy_sidecar_rejects_incomplete_wrong_geometry_and_missing_coverage() {
        let mut value = serde_json::json!({"format":"tempo-mtk-emmc-1","complete":false});
        assert!(validate_legacy_metadata(&value, 0).is_err());
        value["complete"] = true.into();
        value["device"] = serde_json::json!({"hwcode":0x6582,"emmc_user_size":Y2_USER_SIZE,"emmc_boot1_size":Y2_BOOT_SIZE,"emmc_boot2_size":Y2_BOOT_SIZE});
        value["boot1"] = serde_json::json!({"file":"boot1.img","size":Y2_BOOT_SIZE});
        value["boot2"] = serde_json::json!({"file":"boot2.img","size":Y2_BOOT_SIZE});
        value["user"] = serde_json::json!({"file":"emmc-user.img.zst","size":Y2_USER_SIZE,"chunk":Y2_USER_SIZE,"chunks":[{"index":0,"offset":0,"length":Y2_USER_SIZE,"frame_offset":0,"frame_size":12,"sha256":"00".repeat(32)}]});
        assert!(validate_legacy_metadata(&value, 12).is_ok());
        value["user"]["chunks"][0]["offset"] = 512.into();
        assert!(validate_legacy_metadata(&value, 12).is_err());
        value["user"]["chunks"][0]["offset"] = 0.into();
        value["device"]["hwcode"] = 0.into();
        assert!(validate_legacy_metadata(&value, 12).is_err());
    }
}
