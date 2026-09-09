//! Resumable legacy-prefix import; durable chunks precede gzip publication.
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{
    Result, Transport, da,
    firmware::{Y2_BOOT_SIZE, Y2_USER_SIZE},
};
const CHUNK: u64 = 64 * 1024 * 1024;
fn number(value: &Value, key: &str) -> Result<u64> {
    value[key]
        .as_u64()
        .ok_or_else(|| format!("Missing backup {key}"))
}
fn digest(hash: Sha256) -> String {
    hash.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
fn checkpoint(root: &Path, value: &Value) -> Result<()> {
    let tmp = root.join(format!("backup-{}.new", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    std::fs::rename(tmp, root.join("backup.json")).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    File::open(root)
        .and_then(|file| file.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(())
}
fn metadata(root: &Path) -> Result<Value> {
    let path = root.join("backup.json");
    if std::fs::metadata(&path).map_err(|e| e.to_string())?.len() > 16 * 1024 * 1024 {
        return Err("Backup metadata exceeds 16 MiB".into());
    }
    let value: Value = serde_json::from_reader(File::open(path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let length = std::fs::metadata(root.join("emmc-user.img.zst"))
        .map_err(|e| e.to_string())?
        .len();
    crate::restore::validate_legacy_prefix(&value, length, false)?;
    Ok(value)
}
fn decode_frame(
    root: &Path,
    part: &Value,
) -> Result<zstd::stream::read::Decoder<'static, std::io::BufReader<std::io::Take<File>>>> {
    let mut file = File::open(root.join("emmc-user.img.zst")).map_err(|e| e.to_string())?;
    file.seek(SeekFrom::Start(number(part, "frame_offset")?))
        .map_err(|e| e.to_string())?;
    zstd::stream::read::Decoder::new(file.take(number(part, "frame_size")?))
        .map_err(|e| e.to_string())
}
fn verify_reader(
    mut input: impl Read,
    length: u64,
    expected: &str,
    cancelled: &AtomicBool,
) -> Result<()> {
    let mut buffer = vec![0; 1024 * 1024];
    let mut remaining = length;
    let mut hasher = Sha256::new();
    while remaining > 0 {
        if cancelled.load(Ordering::Relaxed) {
            return Err("Backup preparation cancelled".into());
        }
        let count = remaining.min(buffer.len() as u64) as usize;
        input
            .read_exact(&mut buffer[..count])
            .map_err(|e| format!("Incomplete backup frame: {e}"))?;
        hasher.update(&buffer[..count]);
        remaining -= count as u64;
    }
    if input.read(&mut buffer[..1]).map_err(|e| e.to_string())? != 0 || digest(hasher) != expected {
        return Err("Backup chunk length/hash does not match sidecar".into());
    }
    Ok(())
}

pub struct Recovery {
    pub root: PathBuf,
    pub metadata: Value,
    pub output: PathBuf,
}
impl Recovery {
    pub fn create(output: &Path) -> Result<Self> {
        if output.exists() {
            return Err("Backup output already exists".into());
        }
        let root = output.with_file_name(format!(
            "{}.resume",
            output
                .file_name()
                .ok_or("Missing output name")?
                .to_string_lossy()
        ));
        crate::package::create_private_directory(&root)?;
        let value = json!({"format":"tempo-mtk-emmc-1","started":format!("unix:{}",std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|e|e.to_string())?.as_secs()),"complete":false,"device":{"hwcode":0x6582,"emmc_user_size":Y2_USER_SIZE,"emmc_boot1_size":Y2_BOOT_SIZE,"emmc_boot2_size":Y2_BOOT_SIZE},"boot1":{"file":"boot1.img","size":Y2_BOOT_SIZE},"boot2":{"file":"boot2.img","size":Y2_BOOT_SIZE},"user":{"file":"emmc-user.img.zst","size":Y2_USER_SIZE,"chunk":CHUNK,"chunks":[]}});
        File::create(root.join("emmc-user.img.zst"))
            .and_then(|file| file.sync_all())
            .map_err(|e| e.to_string())?;
        checkpoint(&root, &value)?;
        Ok(Self {
            root,
            metadata: value,
            output: output.to_owned(),
        })
    }

    pub fn prepare(
        input: &Path,
        output: &Path,
        cancelled: &AtomicBool,
        mut progress: impl FnMut(u64, u64),
    ) -> Result<Self> {
        if output.exists() {
            return Err("Backup output already exists".into());
        }
        let root = output.with_file_name(format!(
            "{}.resume",
            output
                .file_name()
                .ok_or("Missing output filename")?
                .to_string_lossy()
        ));
        let value = metadata(input)?;
        if number(&value["user"], "chunk")? > 1024 * 1024 * 1024 {
            return Err("Legacy chunk exceeds 1 GiB".into());
        }
        for name in ["boot1", "boot2"] {
            if value[name]["sha256"].is_null() {
                if value["user"]["chunks"]
                    .as_array()
                    .is_none_or(|chunks| !chunks.is_empty())
                {
                    return Err("Backup contains USER chunks without completed boot regions".into());
                }
                continue;
            }
            verify_reader(
                File::open(input.join(format!("{name}.img"))).map_err(|e| e.to_string())?,
                Y2_BOOT_SIZE,
                value[name]["sha256"].as_str().ok_or("Missing boot hash")?,
                cancelled,
            )?;
        }
        let chunks = value["user"]["chunks"].as_array().ok_or("Missing chunks")?;
        let mut length = 0;
        let mut compressed = 0;
        for part in chunks {
            verify_reader(
                decode_frame(input, part)?,
                number(part, "length")?,
                part["sha256"].as_str().ok_or("Missing chunk hash")?,
                cancelled,
            )?;
            length += number(part, "length")?;
            compressed += number(part, "frame_size")?;
            progress(length, Y2_USER_SIZE);
        }
        let same = input.canonicalize().ok() == root.canonicalize().ok() && root.exists();
        if same {
            return Ok(Self {
                root,
                metadata: value,
                output: output.to_owned(),
            });
        }
        crate::package::create_private_directory(&root)?;
        let copied = (|| -> Result<()> {
            for name in ["boot1.img", "boot2.img"] {
                if value[name.trim_end_matches(".img")]["sha256"].is_null() {
                    continue;
                }
                std::fs::copy(input.join(name), root.join(name)).map_err(|e| e.to_string())?;
                File::open(root.join(name))
                    .and_then(|f| f.sync_all())
                    .map_err(|e| e.to_string())?;
            }
            let mut source = File::open(input.join("emmc-user.img.zst"))
                .map_err(|e| e.to_string())?
                .take(compressed);
            let mut target =
                File::create(root.join("emmc-user.img.zst")).map_err(|e| e.to_string())?;
            if std::io::copy(&mut source, &mut target).map_err(|e| e.to_string())? != compressed {
                return Err("Backup prefix changed during copy".into());
            }
            target.sync_all().map_err(|e| e.to_string())?;
            checkpoint(&root, &value)
        })();
        if let Err(error) = copied {
            let _ = std::fs::remove_dir_all(&root);
            return Err(error);
        }
        Ok(Self {
            root,
            metadata: value,
            output: output.to_owned(),
        })
    }
}
struct Compare<R> {
    expected: R,
    compared: u64,
}
impl<R: Read> da::BackupSink for Compare<R> {
    async fn chunk(&mut self, bytes: &[u8], _: u64, _: u64) -> Result<()> {
        let mut expected = vec![0; bytes.len()];
        self.expected
            .read_exact(&mut expected)
            .map_err(|e| e.to_string())?;
        if expected != bytes {
            return Err(format!(
                "Connected device differs from backup prefix at byte {}",
                self.compared
            ));
        }
        self.compared += bytes.len() as u64;
        Ok(())
    }
}
struct Raw(File);
impl da::BackupSink for Raw {
    async fn chunk(&mut self, bytes: &[u8], _: u64, _: u64) -> Result<()> {
        self.0.write_all(bytes).map_err(|e| e.to_string())
    }
}
struct Frame<'a> {
    encoder: zstd::stream::write::Encoder<'a, File>,
    hasher: Sha256,
    base: u64,
    processing_us: u128,
}
impl da::BackupSink for Frame<'_> {
    async fn chunk(&mut self, bytes: &[u8], completed: u64, _: u64) -> Result<()> {
        let processing_started = std::time::Instant::now();
        self.encoder.write_all(bytes).map_err(|e| e.to_string())?;
        self.hasher.update(bytes);
        self.processing_us += processing_started.elapsed().as_micros();
        println!(
            "{}",
            json!({"event":"progress","completed":self.base+completed,"total":Y2_USER_SIZE})
        );
        Ok(())
    }
}

/// Compare every imported prefix byte with the device, then persist missing
/// frames.
pub async fn capture(
    port: &mut impl Transport,
    geometry: &da::Geometry,
    recovery: &mut Recovery,
) -> Result<()> {
    if !geometry.is_y2() {
        return Err("Backup resume requires exact Y2 geometry".into());
    }
    capture_regions(port, geometry, recovery).await
}
async fn capture_regions(
    port: &mut impl Transport,
    geometry: &da::Geometry,
    recovery: &mut Recovery,
) -> Result<()> {
    let capacity = geometry.image_size()?;
    let user_start = geometry.boot1 + geometry.boot2 + geometry.rpmb;
    for (name, partition, size) in [("boot1", 1, geometry.boot1), ("boot2", 2, geometry.boot2)] {
        let path = recovery.root.join(format!("{name}.img"));
        if recovery.metadata[name]["sha256"].is_string() {
            let input = File::open(&path).map_err(|e| e.to_string())?;
            let mut compare = Compare {
                expected: input,
                compared: 0,
            };
            da::read_hardware_region(port, geometry, partition, 0, size, &mut compare).await?;
        } else {
            let partial = recovery.root.join(format!("{name}.partial"));
            let mut sink = Raw(File::create(&partial).map_err(|e| e.to_string())?);
            da::read_hardware_region(port, geometry, partition, 0, size, &mut sink).await?;
            sink.0.sync_all().map_err(|e| e.to_string())?;
            drop(sink);
            let bytes = std::fs::read(&partial).map_err(|e| e.to_string())?;
            if bytes.len() as u64 != size {
                return Err("Boot backup length mismatch".into());
            }
            std::fs::rename(partial, path).map_err(|e| e.to_string())?;
            recovery.metadata[name]["sha256"] = json!(digest(Sha256::new().chain_update(&bytes)));
            checkpoint(&recovery.root, &recovery.metadata)?;
        }
    }
    let existing = recovery.metadata["user"]["chunks"]
        .as_array()
        .ok_or("Missing chunks")?
        .clone();
    let mut offset = 0;
    let mut frame_offset = 0;
    for part in &existing {
        let length = number(part, "length")?;
        let mut compare = Compare {
            expected: decode_frame(&recovery.root, part)?,
            compared: offset,
        };
        let mut checked = 0;
        while checked < length {
            let count = (length - checked).min(CHUNK);
            da::read_region(
                port,
                8,
                capacity,
                user_start + offset + checked,
                count,
                &mut compare,
            )
            .await?;
            checked += count;
        }
        offset += length;
        frame_offset += number(part, "frame_size")?;
        println!(
            "{}",
            json!({"event":"backup-prefix-verified","completed":offset,"total":Y2_USER_SIZE})
        );
    }
    // RPMB is copied only as the DA read view, never as a restorable write
    // target.
    let rpmb = File::create(recovery.root.join("rpmb.img")).map_err(|e| e.to_string())?;
    let mut sink = Raw(rpmb);
    da::read_region(
        port,
        8,
        capacity,
        geometry.boot1 + geometry.boot2,
        geometry.rpmb,
        &mut sink,
    )
    .await?;
    sink.0.sync_all().map_err(|e| e.to_string())?;
    let rpmb_bytes = std::fs::read(recovery.root.join("rpmb.img")).map_err(|e| e.to_string())?;
    recovery.metadata["rpmb"] =
        json!({"size":geometry.rpmb,"sha256":digest(Sha256::new().chain_update(&rpmb_bytes))});
    let chunk = number(&recovery.metadata["user"], "chunk")?;
    if chunk > 1024 * 1024 * 1024 {
        return Err("Legacy chunk size exceeds 1 GiB".into());
    }
    while offset < geometry.user {
        let length = chunk.min(geometry.user - offset);
        let mut file = OpenOptions::new()
            .write(true)
            .open(recovery.root.join("emmc-user.img.zst"))
            .map_err(|e| e.to_string())?;
        file.set_len(frame_offset).map_err(|e| e.to_string())?;
        file.seek(SeekFrom::Start(frame_offset))
            .map_err(|e| e.to_string())?;
        let mut encoder = zstd::stream::write::Encoder::new(file, 3).map_err(|e| e.to_string())?;
        encoder.include_checksum(true).map_err(|e| e.to_string())?;
        encoder
            .set_pledged_src_size(Some(length))
            .map_err(|e| e.to_string())?;
        let mut sink = Frame {
            encoder,
            hasher: Sha256::new(),
            base: offset,
            processing_us: 0,
        };
        // Bound individual DA commands even when the imported legacy frame is
        // larger.
        let mut completed = 0;
        while completed < length {
            let count = (length - completed).min(CHUNK);
            sink.base = offset + completed;
            da::read_region(
                port,
                8,
                capacity,
                user_start + offset + completed,
                count,
                &mut sink,
            )
            .await?;
            completed += count;
        }
        let file = sink.encoder.finish().map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        let frame_size = file.metadata().map_err(|e| e.to_string())?.len() - frame_offset;
        drop(file);
        let chunks = recovery.metadata["user"]["chunks"]
            .as_array_mut()
            .ok_or("Missing chunks")?;
        let index = chunks.len();
        chunks.push(json!({"index":index,"offset":offset,"length":length,"frame_offset":frame_offset,"frame_size":frame_size,"sha256":digest(sink.hasher)}));
        offset += length;
        frame_offset += frame_size;
        recovery.metadata["complete"] = json!(offset == geometry.user);
        checkpoint(&recovery.root, &recovery.metadata)?;
        println!(
            "{}",
            json!({"event":"backup-processing-timing",
            "message":"Backup compression and hashing timing", "bytes":length,
            "processing_ms":sink.processing_us as f64 / 1000.0})
        );
    }
    recovery.metadata["complete"] = json!(true);
    checkpoint(&recovery.root, &recovery.metadata)?;
    Ok(())
}

pub fn finish(
    recovery: &Recovery,
    cancelled: &AtomicBool,
    mut progress: impl FnMut(u64, u64),
) -> Result<()> {
    finish_regions(
        recovery,
        cancelled,
        &mut progress,
        Y2_BOOT_SIZE * 2 + 0x80000 + Y2_USER_SIZE,
    )
}
fn finish_regions(
    recovery: &Recovery,
    cancelled: &AtomicBool,
    progress: &mut impl FnMut(u64, u64),
    total: u64,
) -> Result<()> {
    if recovery.metadata["complete"] != true {
        return Err("Backup is not complete".into());
    }
    let partial = recovery.output.with_file_name(format!(
        "{}.partial",
        recovery
            .output
            .file_name()
            .ok_or("Missing output name")?
            .to_string_lossy()
    ));
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&partial)
        .map_err(|e| e.to_string())?;
    let result = (|| -> Result<()> {
        let mut gzip = flate2::write::GzEncoder::new(file, flate2::Compression::fast());
        let mut completed = 0u64;
        let mut buffer = vec![0; 1024 * 1024];
        let mut copy = |mut input: Box<dyn Read>, length: u64, expected: &str| -> Result<()> {
            let mut remaining = length;
            let mut hasher = Sha256::new();
            while remaining > 0 {
                if cancelled.load(Ordering::Relaxed) {
                    return Err("Backup finalization cancelled; recovery directory retained".into());
                }
                let count = remaining.min(buffer.len() as u64) as usize;
                input
                    .read_exact(&mut buffer[..count])
                    .map_err(|e| e.to_string())?;
                gzip.write_all(&buffer[..count])
                    .map_err(|e| e.to_string())?;
                hasher.update(&buffer[..count]);
                remaining -= count as u64;
                completed += count as u64;
                progress(completed, total);
            }
            if input.read(&mut buffer[..1]).map_err(|e| e.to_string())? != 0
                || digest(hasher) != expected
            {
                return Err("Backup changed before gzip finalization".into());
            }
            Ok(())
        };
        for name in ["boot1", "boot2", "rpmb"] {
            copy(
                Box::new(
                    File::open(recovery.root.join(format!("{name}.img")))
                        .map_err(|e| e.to_string())?,
                ),
                number(&recovery.metadata[name], "size")?,
                recovery.metadata[name]["sha256"]
                    .as_str()
                    .ok_or("Missing region hash")?,
            )?;
        }
        for part in recovery.metadata["user"]["chunks"]
            .as_array()
            .ok_or("Missing chunks")?
        {
            copy(
                Box::new(decode_frame(&recovery.root, part)?),
                number(part, "length")?,
                part["sha256"].as_str().ok_or("Missing frame hash")?,
            )?;
        }
        if completed != total {
            return Err("Final backup does not match continuous Y2 geometry".into());
        }
        let file = gzip.finish().map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        std::fs::hard_link(&partial, &recovery.output).map_err(|e| e.to_string())?;
        Ok(())
    })();
    let _ = std::fs::remove_file(partial);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temp() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "tempo-resume-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&path).unwrap();
        path
    }
    fn sha(bytes: &[u8]) -> String {
        digest(Sha256::new().chain_update(bytes))
    }
    #[test]
    fn verifies_frame_boundaries_hash_and_cancellation() {
        let data = vec![7; 512];
        let expected = sha(&data);
        assert!(verify_reader(&data[..], 512, &expected, &AtomicBool::new(false)).is_ok());
        assert!(verify_reader(&data[..511], 512, &expected, &AtomicBool::new(false)).is_err());
        assert!(verify_reader(&data[..], 511, &expected, &AtomicBool::new(false)).is_err());
        assert!(verify_reader(&data[..], 512, &expected, &AtomicBool::new(true)).is_err());
        assert!(verify_reader(&data[..], 512, &"0".repeat(64), &AtomicBool::new(false)).is_err());
    }
    #[test]
    fn clones_only_validated_prefix_and_preserves_original() {
        let input = temp();
        let output = input.join("finished.gz");
        let boot = vec![0; Y2_BOOT_SIZE as usize];
        let data = vec![7; 512];
        let frame = zstd::stream::encode_all(&data[..], 3).unwrap();
        for name in ["boot1", "boot2"] {
            std::fs::write(input.join(format!("{name}.img")), &boot).unwrap();
        }
        let value = json!({"format":"tempo-mtk-emmc-1","complete":false,"device":{"hwcode":0x6582,"emmc_user_size":Y2_USER_SIZE,"emmc_boot1_size":Y2_BOOT_SIZE,"emmc_boot2_size":Y2_BOOT_SIZE},"boot1":{"file":"boot1.img","size":Y2_BOOT_SIZE,"sha256":sha(&boot)},"boot2":{"file":"boot2.img","size":Y2_BOOT_SIZE,"sha256":sha(&boot)},"user":{"file":"emmc-user.img.zst","size":Y2_USER_SIZE,"chunk":512,"chunks":[{"index":0,"offset":0,"length":512,"frame_offset":0,"frame_size":frame.len(),"sha256":sha(&data)}]}});
        checkpoint(&input, &value).unwrap();
        let mut incomplete = frame.clone();
        incomplete.extend_from_slice(b"unfinished-frame");
        std::fs::write(input.join("emmc-user.img.zst"), &incomplete).unwrap();
        let recovery =
            Recovery::prepare(&input, &output, &AtomicBool::new(false), |_, _| {}).unwrap();
        assert_eq!(
            std::fs::read(recovery.root.join("emmc-user.img.zst")).unwrap(),
            frame
        );
        assert_eq!(
            std::fs::read(input.join("emmc-user.img.zst")).unwrap(),
            incomplete
        );
        let mut bad = value;
        bad["user"]["chunks"][0]["sha256"] = json!("0".repeat(64));
        checkpoint(&input, &bad).unwrap();
        assert!(
            Recovery::prepare(
                &input,
                &input.join("other.gz"),
                &AtomicBool::new(false),
                |_, _| {}
            )
            .is_err()
        );
        assert!(!input.join("other.gz.resume").exists());
        std::fs::remove_dir_all(input).unwrap();
    }
    #[derive(Clone)]
    enum Step {
        Write(Vec<u8>),
        Read(Vec<u8>),
    }
    struct Replay(std::collections::VecDeque<Step>);
    impl Transport for Replay {
        async fn write(&mut self, bytes: &[u8]) -> Result<()> {
            match self.0.pop_front() {
                Some(Step::Write(expected)) if expected == bytes => Ok(()),
                _ => Err(format!("Unexpected write {bytes:?}")),
            }
        }
        async fn read(&mut self, _: usize) -> Result<Vec<u8>> {
            match self.0.pop_front() {
                Some(Step::Read(bytes)) => Ok(bytes),
                _ => Err("Unexpected read".into()),
            }
        }
        async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
            Err("Unexpected control".into())
        }
    }
    fn read(partition: u8, address: u64, data: &[u8]) -> Vec<Step> {
        let checksum = data
            .iter()
            .fold(0u16, |sum, b| sum.wrapping_add(u16::from(*b)));
        vec![
            Step::Write(vec![0x72]),
            Step::Read(vec![0x5a]),
            Step::Read(vec![1]),
            Step::Write(vec![0x60]),
            Step::Read(vec![0x5a]),
            Step::Write(vec![partition]),
            Step::Read(vec![0x5a]),
            Step::Write(vec![0xd6]),
            Step::Write(vec![0x0c]),
            Step::Write(vec![2]),
            Step::Write(address.to_be_bytes().to_vec()),
            Step::Write((data.len() as u64).to_be_bytes().to_vec()),
            Step::Read(vec![0x5a]),
            Step::Write(0x100000u32.to_be_bytes().to_vec()),
            Step::Read(data.to_vec()),
            Step::Read(checksum.to_be_bytes().to_vec()),
            Step::Write(vec![0x5a]),
        ]
    }
    #[test]
    fn checks_existing_device_bytes_then_commits_only_complete_new_frame() {
        let root = temp();
        let data = vec![0; 512];
        let frame = zstd::stream::encode_all(&data[..], 3).unwrap();
        for name in ["boot1.img", "boot2.img"] {
            std::fs::write(root.join(name), &data).unwrap();
        }
        std::fs::write(root.join("emmc-user.img.zst"), &frame).unwrap();
        let mut recovery = Recovery {
            root: root.clone(),
            output: root.join("out.gz"),
            metadata: json!({"complete":false,"user":{"chunk":512,"chunks":[{"index":0,"offset":0,"length":512,"frame_offset":0,"frame_size":frame.len(),"sha256":sha(&data)}]}}),
        };
        let geometry = da::Geometry {
            boot1: 512,
            boot2: 512,
            rpmb: 512,
            user: 1024,
        };
        let new = vec![2; 512];
        let boot2 = vec![3; 512];
        let mut steps = std::collections::VecDeque::new();
        steps.extend(read(8, 0, &data));
        steps.extend(read(8, 512, &boot2));
        steps.extend(read(8, 1536, &data));
        steps.extend(read(8, 1024, &data));
        steps.extend(read(8, 2048, &new));
        // A dropped checksum leaves no newly committed USER frame.
        let mut interrupted = steps.clone();
        interrupted.truncate(interrupted.len() - 2);
        let mut failed = Replay(interrupted);
        assert!(
            pollster::block_on(capture_regions(&mut failed, &geometry, &mut recovery)).is_err()
        );
        assert_eq!(
            recovery.metadata["user"]["chunks"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let mut port = Replay(steps);
        pollster::block_on(capture_regions(&mut port, &geometry, &mut recovery)).unwrap();
        assert!(port.0.is_empty());
        assert_eq!(recovery.metadata["complete"], true);
        let saved: Value =
            serde_json::from_reader(File::open(root.join("backup.json")).unwrap()).unwrap();
        assert_eq!(saved["user"]["chunks"].as_array().unwrap().len(), 2);
        verify_reader(
            decode_frame(&root, &saved["user"]["chunks"][1]).unwrap(),
            512,
            &sha(&new),
            &AtomicBool::new(false),
        )
        .unwrap();
        recovery.metadata["boot1"]["size"] = json!(512);
        recovery.metadata["boot2"]["size"] = json!(512);
        finish_regions(&recovery, &AtomicBool::new(false), &mut |_, _| {}, 2560).unwrap();
        let mut decoded = Vec::new();
        flate2::read::GzDecoder::new(File::open(&recovery.output).unwrap())
            .read_to_end(&mut decoded)
            .unwrap();
        assert_eq!(decoded.len(), 2560);
        assert_eq!(&decoded[512..1024], &boot2);
        assert_eq!(&decoded[2048..], &new);
        assert!(finish_regions(&recovery, &AtomicBool::new(false), &mut |_, _| {}, 2560).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn empty_recovery_can_resume_before_first_device_read() {
        let root = temp();
        let output = root.join("backup.gz");
        let created = Recovery::create(&output).unwrap();
        let loaded =
            Recovery::prepare(&created.root, &output, &AtomicBool::new(false), |_, _| {}).unwrap();
        assert_eq!(loaded.root, created.root);
        assert_eq!(loaded.metadata["complete"], false);
        assert!(
            loaded.metadata["user"]["chunks"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
