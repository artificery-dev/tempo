//! Versioned `.y2-firmware` manifest and write-plan validation.
//!
//! Archive decoding and storage writes are intentionally separate. A package
//! must pass this validation before a device is connected or any DA write
//! command is made available.
use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{Result, da};

pub const FORMAT: &str = "dev.artificery.tempo.y2-firmware";
pub const FORMAT_VERSION: u32 = 1;
pub const Y2_BOOT_SIZE: u64 = 0x400000;
pub const Y2_USER_SIZE: u64 = 0x1d2000000;
const BLOCK_SIZE: u64 = 512;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub format: String,
    pub format_version: u32,
    pub device: Device,
    pub firmware: Firmware,
    pub images: Vec<Image>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Device {
    pub id: String,
    pub hardware_code: u16,
    pub hardware_subcode: u16,
    pub storage: Storage,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Storage {
    pub boot1: u64,
    pub boot2: u64,
    pub user: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Firmware {
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// Optional offline PNG preview; never a flashable image.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Image {
    pub file: String,
    pub size: u64,
    pub sha256: String,
    pub writes: Vec<Write>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Region {
    Boot1,
    Boot2,
    User,
}

impl Region {
    pub fn capacity(self) -> u64 {
        match self {
            Self::Boot1 | Self::Boot2 => Y2_BOOT_SIZE,
            Self::User => Y2_USER_SIZE,
        }
    }

    pub fn da_partition(self) -> u8 {
        match self {
            Self::Boot1 => 1,
            Self::Boot2 => 2,
            Self::User => 8,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Write {
    pub name: String,
    pub region: Region,
    pub source_offset: u64,
    pub target_offset: u64,
    pub length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlannedWrite {
    pub image: usize,
    pub mapping: usize,
    pub region: Region,
    pub source_offset: u64,
    pub target_offset: u64,
    pub length: u64,
}

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let manifest: Self = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> Result<()> {
        if self.format != FORMAT || self.format_version != FORMAT_VERSION {
            return Err("Unsupported Y2 firmware format or version".into());
        }
        if self.device.id != "innioasis-y2"
            || self.device.hardware_code != 0x6582
            || self.device.hardware_subcode != 0x8a00
            || self.device.storage.boot1 != Y2_BOOT_SIZE
            || self.device.storage.boot2 != Y2_BOOT_SIZE
            || self.device.storage.user != Y2_USER_SIZE
        {
            return Err("Firmware package is not for the verified Innioasis Y2 geometry".into());
        }
        if [
            self.firmware.id.as_str(),
            self.firmware.name.as_str(),
            self.firmware.version.as_str(),
        ]
        .iter()
        .any(|value| value.trim().is_empty())
        {
            return Err("Firmware identity fields cannot be empty".into());
        }
        if let Some(icon) = &self.firmware.icon {
            let data = icon
                .strip_prefix("data:image/png;base64,")
                .ok_or("Firmware icon must be an embedded PNG")?;
            if data.is_empty()
                || data.len() > 128 * 1024
                || !data.len().is_multiple_of(4)
                || !data
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
            {
                return Err("Invalid or oversized firmware icon".into());
            }
        }
        if self.images.is_empty() {
            return Err("Firmware package contains no images".into());
        }
        if self.images.len() > 256 {
            return Err("Firmware package contains too many images".into());
        }

        let mut files = HashSet::new();
        let mut destinations = Vec::new();
        for image in &self.images {
            if !files.insert(image.file.as_str()) {
                return Err(format!("Duplicate firmware image {}", image.file));
            }
            if !valid_image_path(&image.file) {
                return Err(format!("Unsafe firmware image path {}", image.file));
            }
            if image.size == 0
                || image.sha256.len() != 64
                || !image
                    .sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            {
                return Err(format!("Invalid size or SHA-256 for {}", image.file));
            }
            if image.writes.is_empty() {
                return Err(format!("Firmware image {} has no writes", image.file));
            }
            if image.writes.len() > 4096 {
                return Err(format!(
                    "Firmware image {} has too many mappings",
                    image.file
                ));
            }
            for write in &image.writes {
                if write.name.trim().is_empty()
                    || write.length == 0
                    || !write.source_offset.is_multiple_of(BLOCK_SIZE)
                    || !write.target_offset.is_multiple_of(BLOCK_SIZE)
                    || !write.length.is_multiple_of(BLOCK_SIZE)
                {
                    return Err(format!("Invalid or unaligned write {}", write.name));
                }
                let source_end = write
                    .source_offset
                    .checked_add(write.length)
                    .ok_or("Firmware source range overflow")?;
                let target_end = write
                    .target_offset
                    .checked_add(write.length)
                    .ok_or("Firmware target range overflow")?;
                if source_end > image.size || target_end > write.region.capacity() {
                    return Err(format!(
                        "Write {} is outside its image or eMMC region",
                        write.name
                    ));
                }
                if destinations.iter().any(|(region, start, end)| {
                    *region == write.region && write.target_offset < *end && target_end > *start
                }) {
                    return Err(format!("Write {} overlaps another destination", write.name));
                }
                destinations.push((write.region, write.target_offset, target_end));
            }
        }
        Ok(())
    }

    /// Produce the only ranges the writer may consume. BOOT1 is the
    /// wrapped preloader region and is absent unless the user has explicitly
    /// acknowledged preloader flashing in the current installation session.
    pub fn write_plan(&self, allow_preloader: bool) -> Result<Vec<PlannedWrite>> {
        self.validate()?;
        Ok(self
            .images
            .iter()
            .enumerate()
            .flat_map(|(image_index, image)| {
                image
                    .writes
                    .iter()
                    .enumerate()
                    .filter_map(move |(mapping_index, write)| {
                        if write.region == Region::Boot1 && !allow_preloader {
                            return None;
                        }
                        Some(PlannedWrite {
                            image: image_index,
                            mapping: mapping_index,
                            region: write.region,
                            source_offset: write.source_offset,
                            target_offset: write.target_offset,
                            length: write.length,
                        })
                    })
            })
            .collect())
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct FlashProgress {
    pub phase: &'static str,
    pub completed: u64,
    pub total: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mapping: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<Region>,
}

#[allow(async_fn_in_trait)]
pub trait FirmwareSource {
    /// Return exactly `length` uncompressed bytes from a manifest image.
    async fn chunk(&mut self, image: usize, offset: u64, length: usize) -> Result<Vec<u8>>;
}

#[allow(async_fn_in_trait)]
pub trait FlashObserver {
    async fn progress(&mut self, event: FlashProgress) -> Result<()>;
}

fn image_total(manifest: &Manifest) -> Result<u64> {
    manifest.images.iter().try_fold(0u64, |total, image| {
        total
            .checked_add(image.size)
            .ok_or_else(|| "Firmware size overflow".into())
    })
}

fn transfer_total(plan: &[PlannedWrite]) -> Result<u64> {
    plan.iter().try_fold(0u64, |total, write| {
        total
            .checked_add(write.length.checked_mul(2).ok_or("Flash size overflow")?)
            .ok_or_else(|| "Flash size overflow".into())
    })
}

async fn verify_images(
    manifest: &Manifest,
    source: &mut impl FirmwareSource,
    observer: &mut impl FlashObserver,
    total: u64,
) -> Result<u64> {
    let mut completed = 0u64;
    for (index, image) in manifest.images.iter().enumerate() {
        let mut hasher = Sha256::new();
        let mut offset = 0u64;
        while offset < image.size {
            let length = (image.size - offset).min(0x100000) as usize;
            let bytes = source.chunk(index, offset, length).await?;
            if bytes.len() != length {
                return Err(format!(
                    "Firmware image {} ended at byte {} of {}",
                    image.file,
                    offset + bytes.len() as u64,
                    image.size
                ));
            }
            hasher.update(&bytes);
            offset += length as u64;
            completed += length as u64;
            observer
                .progress(FlashProgress {
                    phase: "validating",
                    completed,
                    total,
                    mapping: Some(image.file.clone()),
                    region: None,
                })
                .await?;
        }
        let actual = hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        if actual != image.sha256 {
            return Err(format!("SHA-256 mismatch for {}", image.file));
        }
    }
    Ok(completed)
}

/// Validate a manifest and hash all uncompressed images without opening a
/// device. Frontends use this while selecting/staging a package.
pub async fn verify(
    manifest: &Manifest,
    source: &mut impl FirmwareSource,
    observer: &mut impl FlashObserver,
) -> Result<u64> {
    manifest.validate()?;
    let total = image_total(manifest)?;
    verify_images(manifest, source, observer, total).await?;
    Ok(total)
}

pub(crate) fn validate_preloader(bytes: &[u8], write: &PlannedWrite) -> Result<()> {
    if write.target_offset != 0 || write.length != Y2_BOOT_SIZE {
        return Err("Preloader flashing requires one complete 4 MiB BOOT1 image".into());
    }
    if bytes.len() < 0x1000
        || &bytes[..9] != b"EMMC_BOOT"
        || &bytes[0x200..0x205] != b"BRLYT"
        || &bytes[0x800..0x804] != b"MMM\x01"
    {
        return Err(
            "BOOT1 is not a wrapped Y2 preloader (EMMC_BOOT, BRLYT, or GFH is missing)".into(),
        );
    }
    let le32 = |offset: usize| {
        u32::from_le_bytes(
            bytes[offset..offset + 4]
                .try_into()
                .expect("checked header"),
        ) as u64
    };
    let first_total = le32(0x210);
    let second_total = le32(0x220);
    let gfh_length = le32(0x820);
    if first_total == 0
        || first_total != second_total
        || !first_total.is_multiple_of(512)
        || first_total > Y2_BOOT_SIZE
        || gfh_length == 0
        || 0x800u64
            .checked_add(gfh_length)
            .is_none_or(|end| end > first_total)
    {
        return Err("BOOT1 has inconsistent BRLYT or GFH length fields".into());
    }
    Ok(())
}

struct ImageSource<'a, S> {
    source: &'a mut S,
    image: usize,
}

impl<S: FirmwareSource> da::FlashSource for ImageSource<'_, S> {
    async fn chunk(&mut self, offset: u64, length: usize) -> Result<Vec<u8>> {
        self.source.chunk(self.image, offset, length).await
    }
}

struct WriteProgress<'a, O> {
    observer: &'a mut O,
    base: u64,
    total: u64,
    mapping: String,
    region: Region,
}

impl<O: FlashObserver> da::FlashSink for WriteProgress<'_, O> {
    async fn progress(&mut self, completed: u64, _: u64) -> Result<()> {
        self.observer
            .progress(FlashProgress {
                phase: "writing",
                completed: self.base + completed,
                total: self.total,
                mapping: Some(self.mapping.clone()),
                region: Some(self.region),
            })
            .await
    }
}

struct VerifySink<'a, S, O> {
    source: &'a mut S,
    observer: &'a mut O,
    image: usize,
    source_offset: u64,
    compared: u64,
    base: u64,
    total: u64,
    mapping: String,
    region: Region,
    strict: bool,
    matches: bool,
}

impl<S: FirmwareSource, O: FlashObserver> da::BackupSink for VerifySink<'_, S, O> {
    async fn chunk(&mut self, bytes: &[u8], _: u64, _: u64) -> Result<()> {
        let expected = self
            .source
            .chunk(self.image, self.source_offset + self.compared, bytes.len())
            .await?;
        if expected != bytes {
            self.matches = false;
            if self.strict {
                return Err(format!(
                    "Read-back verification failed for {} at byte {}",
                    self.mapping, self.compared
                ));
            }
        }
        self.compared += bytes.len() as u64;
        self.observer
            .progress(FlashProgress {
                phase: if self.strict { "verifying" } else { "checking" },
                completed: self.base + self.compared,
                total: self.total,
                mapping: Some(self.mapping.clone()),
                region: Some(self.region),
            })
            .await
    }
}

fn plan(
    geometry: &da::Geometry,
    manifest: &Manifest,
    allow_preloader: bool,
) -> Result<Vec<PlannedWrite>> {
    if !geometry.is_y2() {
        return Err("The eMMC geometry does not match an Innioasis Y2".into());
    }
    let mut plan = manifest.write_plan(allow_preloader)?;
    if plan.is_empty() {
        return Err("The guarded firmware package has no ranges to write".into());
    }
    // A recoverable USER or BOOT2 failure must never be followed by a BOOT1
    // write. Keep the explicitly enabled preloader operation last.
    plan.sort_by_key(|write| write.region == Region::Boot1);
    Ok(plan)
}

struct Execution {
    completed: u64,
    total: u64,
    resume: bool,
    verify_write: bool,
}
async fn execute_plan(
    port: &mut impl crate::Transport,
    geometry: &da::Geometry,
    manifest: &Manifest,
    source: &mut impl FirmwareSource,
    observer: &mut impl FlashObserver,
    plan: Vec<PlannedWrite>,
    execution: Execution,
) -> Result<u64> {
    let Execution {
        mut completed,
        total,
        resume,
        verify_write,
    } = execution;
    let boot_writes: Vec<_> = plan
        .iter()
        .filter(|write| write.region == Region::Boot1)
        .collect();
    if !boot_writes.is_empty() {
        if boot_writes.len() != 1 {
            return Err("Preloader flashing requires exactly one BOOT1 mapping".into());
        }
        let write = boot_writes[0];
        let header = source
            .chunk(write.image, write.source_offset, 0x1000)
            .await?;
        validate_preloader(&header, write)?;
    }

    const OPERATION_SIZE: u64 = 64 * 1024 * 1024;
    for write in plan {
        let name = manifest.images[write.image].writes[write.mapping]
            .name
            .clone();
        let mut range_completed = 0u64;
        while range_completed < write.length {
            let length = (write.length - range_completed).min(OPERATION_SIZE);
            if resume {
                let mut checking = VerifySink {
                    source,
                    observer,
                    image: write.image,
                    source_offset: write.source_offset + range_completed,
                    compared: 0,
                    base: completed,
                    total,
                    mapping: name.clone(),
                    region: write.region,
                    strict: false,
                    matches: true,
                };
                da::read_hardware_region(
                    port,
                    geometry,
                    write.region.da_partition(),
                    write.target_offset + range_completed,
                    length,
                    &mut checking,
                )
                .await?;
                completed += length;
                if checking.matches {
                    completed += length * (1 + u64::from(verify_write));
                    observer
                        .progress(FlashProgress {
                            phase: "skipped",
                            completed,
                            total,
                            mapping: Some(name.clone()),
                            region: Some(write.region),
                        })
                        .await?;
                    range_completed += length;
                    continue;
                }
            }
            {
                let mut image_source = ImageSource {
                    source,
                    image: write.image,
                };
                let mut progress = WriteProgress {
                    observer,
                    base: completed,
                    total,
                    mapping: name.clone(),
                    region: write.region,
                };
                da::write_region(
                    port,
                    da::WriteRegion {
                        partition: write.region.da_partition(),
                        capacity: write.region.capacity(),
                        address: write.target_offset + range_completed,
                        length,
                        source_offset: write.source_offset + range_completed,
                    },
                    &mut image_source,
                    &mut progress,
                )
                .await?;
            }
            completed += length;
            if verify_write {
                let mut verify = VerifySink {
                    source,
                    observer,
                    image: write.image,
                    source_offset: write.source_offset + range_completed,
                    compared: 0,
                    base: completed,
                    total,
                    mapping: name.clone(),
                    region: write.region,
                    strict: true,
                    matches: true,
                };
                da::read_hardware_region(
                    port,
                    geometry,
                    write.region.da_partition(),
                    write.target_offset + range_completed,
                    length,
                    &mut verify,
                )
                .await?;
                completed += length;
            }
            range_completed += length;
        }
    }
    Ok(total)
}

/// Validate every image before issuing the first storage command, write each
/// mapped range, then read it back byte for byte. This entry point is useful
/// for callers that have not already staged and verified an immutable source.
pub async fn flash(
    port: &mut impl crate::Transport,
    geometry: &da::Geometry,
    manifest: &Manifest,
    source: &mut impl FirmwareSource,
    observer: &mut impl FlashObserver,
    allow_preloader: bool,
) -> Result<u64> {
    let plan = plan(geometry, manifest, allow_preloader)?;
    let image_bytes = image_total(manifest)?;
    let total = image_bytes
        .checked_add(transfer_total(&plan)?)
        .ok_or("Flash size overflow")?;
    let completed = verify_images(manifest, source, observer, total).await?;
    execute_plan(
        port,
        geometry,
        manifest,
        source,
        observer,
        plan,
        Execution {
            completed,
            total,
            resume: false,
            verify_write: true,
        },
    )
    .await
}

/// Flash an immutable source that the frontend already hashed with [`verify`]
/// before opening the USB device. Structural checks, the preloader wrapper
/// gate, bounds checks, and byte-for-byte read-back still run here.
pub async fn flash_verified(
    port: &mut impl crate::Transport,
    geometry: &da::Geometry,
    manifest: &Manifest,
    source: &mut impl FirmwareSource,
    observer: &mut impl FlashObserver,
    allow_preloader: bool,
) -> Result<u64> {
    let plan = plan(geometry, manifest, allow_preloader)?;
    let total = transfer_total(&plan)?;
    execute_plan(
        port,
        geometry,
        manifest,
        source,
        observer,
        plan,
        Execution {
            completed: 0,
            total,
            resume: false,
            verify_write: true,
        },
    )
    .await
}

/// Resume by comparing destination bytes, never by trusting a host progress
/// flag.
pub async fn resume_verified(
    port: &mut impl crate::Transport,
    geometry: &da::Geometry,
    manifest: &Manifest,
    source: &mut impl FirmwareSource,
    observer: &mut impl FlashObserver,
    allow_preloader: bool,
) -> Result<u64> {
    let plan = plan(geometry, manifest, allow_preloader)?;
    let total = transfer_total(&plan)?
        .checked_div(2)
        .and_then(|bytes| bytes.checked_mul(3))
        .ok_or("Resume work size overflow")?;
    execute_plan(
        port,
        geometry,
        manifest,
        source,
        observer,
        plan,
        Execution {
            completed: 0,
            total,
            resume: true,
            verify_write: true,
        },
    )
    .await
}

/// Execute an already validated immutable package with optional readback.
#[derive(Clone, Copy)]
pub struct WriteOptions {
    pub allow_preloader: bool,
    pub resume: bool,
    pub verify_write: bool,
}
pub async fn flash_with_options(
    port: &mut impl crate::Transport,
    geometry: &da::Geometry,
    manifest: &Manifest,
    source: &mut impl FirmwareSource,
    observer: &mut impl FlashObserver,
    options: WriteOptions,
) -> Result<u64> {
    let plan = plan(geometry, manifest, options.allow_preloader)?;
    let total = (transfer_total(&plan)? / 2)
        .checked_mul(1 + u64::from(options.resume) + u64::from(options.verify_write))
        .ok_or("Flash size overflow")?;
    execute_plan(
        port,
        geometry,
        manifest,
        source,
        observer,
        plan,
        Execution {
            completed: 0,
            total,
            resume: options.resume,
            verify_write: options.verify_write,
        },
    )
    .await
}

fn valid_image_path(path: &str) -> bool {
    path.starts_with("images/")
        && !path.ends_with('/')
        && !path.contains('\\')
        && path
            .split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..")
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    #[test]
    fn optional_icon_roundtrips_without_changing_write_plan() {
        let mut value = manifest();
        let before = value.write_plan(false).unwrap();
        let legacy = serde_json::to_vec(&value).unwrap();
        assert!(Manifest::parse(&legacy).unwrap().firmware.icon.is_none());
        value.firmware.version = "0.9.0".into();
        value.firmware.commit = Some("71e172f29e7a616ba578916307842d68df8df24d".into());
        value.firmware.icon = Some("data:image/png;base64,aWNvbg==".into());
        let encoded = serde_json::to_vec(&value).unwrap();
        let decoded = Manifest::parse(&encoded).unwrap();
        assert_eq!(decoded.firmware.icon, value.firmware.icon);
        assert_eq!(decoded.firmware.version, "0.9.0");
        assert_eq!(decoded.firmware.commit, value.firmware.commit);
        assert_eq!(decoded.write_plan(false).unwrap(), before);
        value.firmware.icon = Some("https://example.test/icon.png".into());
        assert!(value.validate().is_err());
        value.firmware.icon = Some(format!(
            "data:image/png;base64,{}",
            "A".repeat(128 * 1024 + 4)
        ));
        assert!(value.validate().is_err());
    }

    fn manifest() -> Manifest {
        Manifest {
            format: FORMAT.into(),
            format_version: FORMAT_VERSION,
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
                id: "backup".into(),
                name: "Y2 backup".into(),
                version: "2026-09-06".into(),
            },
            images: vec![Image {
                file: "images/emmc.img".into(),
                size: 0x880000 + Y2_USER_SIZE,
                sha256: "a".repeat(64),
                writes: vec![
                    Write {
                        name: "preloader".into(),
                        region: Region::Boot1,
                        source_offset: 0,
                        target_offset: 0,
                        length: Y2_BOOT_SIZE,
                    },
                    Write {
                        name: "boot2".into(),
                        region: Region::Boot2,
                        source_offset: 0x400000,
                        target_offset: 0,
                        length: Y2_BOOT_SIZE,
                    },
                    Write {
                        name: "user".into(),
                        region: Region::User,
                        source_offset: 0x880000,
                        target_offset: 0,
                        length: Y2_USER_SIZE,
                    },
                ],
            }],
        }
    }

    #[test]
    fn canonical_example_parses() {
        Manifest::parse(include_bytes!("../../firmware/example-manifest.json")).unwrap();
    }

    #[test]
    fn preloader_is_removed_from_the_default_plan() {
        let manifest = manifest();
        let guarded = manifest.write_plan(false).unwrap();
        assert_eq!(guarded.len(), 2);
        assert!(guarded.iter().all(|write| write.region != Region::Boot1));
        let acknowledged = manifest.write_plan(true).unwrap();
        assert_eq!(acknowledged.len(), 3);
        assert_eq!(acknowledged[0].source_offset, 0);
        assert_eq!(acknowledged[0].target_offset, 0);
    }

    #[test]
    fn enabled_preloader_is_scheduled_after_recoverable_regions() {
        let geometry = da::Geometry {
            boot1: Y2_BOOT_SIZE,
            boot2: Y2_BOOT_SIZE,
            rpmb: 0x80000,
            user: Y2_USER_SIZE,
        };
        let writes = plan(&geometry, &manifest(), true).unwrap();
        assert_eq!(writes.last().unwrap().region, Region::Boot1);
        assert!(
            writes[..writes.len() - 1]
                .iter()
                .all(|write| write.region != Region::Boot1)
        );
    }

    #[test]
    fn rootfs_mapping_uses_the_raw_mainline_user_offset() {
        let mut manifest = manifest();
        manifest.images[0].size = 0x1_0000_0000;
        manifest.images[0].writes = vec![Write {
            name: "rootfs".into(),
            region: Region::User,
            source_offset: 0,
            target_offset: 0x5180000,
            length: 0x1_0000_0000,
        }];
        let writes = manifest.write_plan(false).unwrap();
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].target_offset, 0x5180000);
        assert_ne!(writes[0].target_offset, 0x5d00000);
    }

    #[test]
    fn source_ranges_cannot_run_past_an_image() {
        let mut manifest = manifest();
        manifest.images[0].writes[2].length += 512;
        assert!(manifest.validate().unwrap_err().contains("outside"));
    }

    #[test]
    fn destination_ranges_cannot_overlap() {
        let mut manifest = manifest();
        manifest.images[0].writes.push(Write {
            name: "overlap".into(),
            region: Region::User,
            source_offset: 0x880000,
            target_offset: 0,
            length: 512,
        });
        assert!(manifest.validate().unwrap_err().contains("overlaps"));
    }

    #[test]
    fn image_paths_cannot_escape_the_archive_directory() {
        let mut manifest = manifest();
        manifest.images[0].file = "images/../preloader.bin".into();
        assert!(manifest.validate().unwrap_err().contains("Unsafe"));
    }

    #[derive(Clone)]
    enum Exchange {
        Write(Vec<u8>),
        Read(Vec<u8>),
    }
    struct Replay(VecDeque<Exchange>);
    impl crate::Transport for Replay {
        async fn read(&mut self, _: usize) -> Result<Vec<u8>> {
            match self.0.pop_front() {
                Some(Exchange::Read(bytes)) => Ok(bytes),
                _ => Err("Unexpected read".into()),
            }
        }
        async fn write(&mut self, bytes: &[u8]) -> Result<()> {
            match self.0.pop_front() {
                Some(Exchange::Write(expected)) if expected == bytes => Ok(()),
                _ => Err(format!("Unexpected write {bytes:02x?}")),
            }
        }
        async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
            Err("Unexpected control".into())
        }
    }
    struct Images(Vec<Vec<u8>>);
    impl FirmwareSource for Images {
        async fn chunk(&mut self, image: usize, offset: u64, length: usize) -> Result<Vec<u8>> {
            self.0
                .get(image)
                .and_then(|bytes| bytes.get(offset as usize..offset as usize + length))
                .map(<[u8]>::to_vec)
                .ok_or_else(|| "Missing source range".into())
        }
    }
    struct Events(Vec<FlashProgress>);
    impl FlashObserver for Events {
        async fn progress(&mut self, event: FlashProgress) -> Result<()> {
            self.0.push(event);
            Ok(())
        }
    }

    #[test]
    fn flashes_then_reads_back_a_manifest_range() {
        let data: Vec<_> = (0..512).map(|value| value as u8).collect();
        let hash = Sha256::digest(&data)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let manifest = Manifest {
            format: FORMAT.into(),
            format_version: FORMAT_VERSION,
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
                id: "test".into(),
                name: "Test".into(),
                version: "1".into(),
            },
            images: vec![Image {
                file: "images/test.bin".into(),
                size: 512,
                sha256: hash,
                writes: vec![Write {
                    name: "test".into(),
                    region: Region::User,
                    source_offset: 0,
                    target_offset: 0,
                    length: 512,
                }],
            }],
        };
        let checksum = data
            .iter()
            .fold(0u16, |sum, byte| sum.wrapping_add(u16::from(*byte)));
        let mut replay = Replay(
            [
                Exchange::Write(vec![0x72]),
                Exchange::Read(vec![0x5a]),
                Exchange::Read(vec![1]),
                Exchange::Write(vec![0x62]),
                Exchange::Write(vec![2]),
                Exchange::Write(vec![8]),
                Exchange::Write(0u64.to_be_bytes().to_vec()),
                Exchange::Write(512u64.to_be_bytes().to_vec()),
                Exchange::Write(0x100000u32.to_be_bytes().to_vec()),
                Exchange::Read(vec![0x5a]),
                Exchange::Write(vec![0x5a]),
                Exchange::Write(data.clone()),
                Exchange::Write(checksum.to_be_bytes().to_vec()),
                Exchange::Read(vec![0x69]),
                Exchange::Write(vec![0x72]),
                Exchange::Read(vec![0x5a]),
                Exchange::Read(vec![1]),
                Exchange::Write(vec![0x60]),
                Exchange::Read(vec![0x5a]),
                Exchange::Write(vec![8]),
                Exchange::Read(vec![0x5a]),
                Exchange::Write(vec![0xd6]),
                Exchange::Write(vec![0x0c]),
                Exchange::Write(vec![2]),
                Exchange::Write(0x880000u64.to_be_bytes().to_vec()),
                Exchange::Write(512u64.to_be_bytes().to_vec()),
                Exchange::Read(vec![0x5a]),
                Exchange::Write(0x100000u32.to_be_bytes().to_vec()),
                Exchange::Read(data.clone()),
                Exchange::Read(checksum.to_be_bytes().to_vec()),
                Exchange::Write(vec![0x5a]),
            ]
            .into(),
        );
        let original_steps = replay.0.clone();
        let read_steps: VecDeque<_> = original_steps
            .iter()
            .skip(original_steps.len() - 17)
            .cloned()
            .collect();
        let mut source = Images(vec![data]);
        let mut events = Events(vec![]);
        let geometry = da::Geometry {
            boot1: Y2_BOOT_SIZE,
            boot2: Y2_BOOT_SIZE,
            rpmb: 0x80000,
            user: Y2_USER_SIZE,
        };
        let verified = pollster::block_on(verify(&manifest, &mut source, &mut events)).unwrap();
        assert_eq!(verified, 512);
        assert_eq!(events.0.last().unwrap().phase, "validating");
        events.0.clear();
        let total = pollster::block_on(flash_verified(
            &mut replay,
            &geometry,
            &manifest,
            &mut source,
            &mut events,
            false,
        ))
        .unwrap();
        assert_eq!(total, 1024);
        assert_eq!(events.0.last().unwrap().phase, "verifying");
        assert_eq!(events.0.last().unwrap().completed, total);
        assert!(replay.0.is_empty());
        // Disabling readback must issue only the recorded write commands.
        let mut unchecked = Replay(
            original_steps
                .iter()
                .take(original_steps.len() - 17)
                .cloned()
                .collect(),
        );
        events.0.clear();
        let bytes = pollster::block_on(flash_with_options(
            &mut unchecked,
            &geometry,
            &manifest,
            &mut source,
            &mut events,
            WriteOptions {
                allow_preloader: false,
                resume: false,
                verify_write: false,
            },
        ))
        .unwrap();
        assert_eq!(bytes, 512);
        assert!(unchecked.0.is_empty());
        assert_eq!(events.0.last().unwrap().phase, "writing");
        assert_eq!(events.0.last().unwrap().completed, 512);
        let mut skipped = Replay(read_steps.clone());
        let bytes = pollster::block_on(flash_with_options(
            &mut skipped,
            &geometry,
            &manifest,
            &mut source,
            &mut events,
            WriteOptions {
                allow_preloader: false,
                resume: true,
                verify_write: false,
            },
        ))
        .unwrap();
        assert_eq!(bytes, 1024);
        assert!(skipped.0.is_empty());
        assert_eq!(events.0.last().unwrap().completed, 1024);
        let mut replay = Replay(read_steps.clone());
        events.0.clear();
        assert_eq!(
            pollster::block_on(resume_verified(
                &mut replay,
                &geometry,
                &manifest,
                &mut source,
                &mut events,
                false
            ))
            .unwrap(),
            1536
        );
        assert!(replay.0.is_empty());
        assert_eq!(events.0.last().unwrap().phase, "skipped");
        let mut mismatching = read_steps;
        if let Exchange::Read(bytes) = &mut mismatching[14] {
            bytes[0] ^= 1;
        }
        let checksum = if let Exchange::Read(bytes) = &mismatching[14] {
            bytes
                .iter()
                .fold(0u16, |sum, b| sum.wrapping_add(u16::from(*b)))
        } else {
            panic!("missing data")
        };
        mismatching[15] = Exchange::Read(checksum.to_be_bytes().to_vec());
        mismatching.extend(original_steps);
        let mut replay = Replay(mismatching);
        events.0.clear();
        assert_eq!(
            pollster::block_on(resume_verified(
                &mut replay,
                &geometry,
                &manifest,
                &mut source,
                &mut events,
                false
            ))
            .unwrap(),
            1536
        );
        assert!(replay.0.is_empty());
        assert_eq!(events.0.last().unwrap().phase, "verifying");
    }

    #[test]
    fn preloader_requires_the_complete_consistent_wrapper() {
        let write = PlannedWrite {
            image: 0,
            mapping: 0,
            region: Region::Boot1,
            source_offset: 0,
            target_offset: 0,
            length: Y2_BOOT_SIZE,
        };
        let mut bytes = vec![0; 0x1000];
        bytes[..9].copy_from_slice(b"EMMC_BOOT");
        bytes[0x200..0x205].copy_from_slice(b"BRLYT");
        bytes[0x800..0x804].copy_from_slice(b"MMM\x01");
        bytes[0x210..0x214].copy_from_slice(&0x20800u32.to_le_bytes());
        bytes[0x220..0x224].copy_from_slice(&0x20800u32.to_le_bytes());
        bytes[0x820..0x824].copy_from_slice(&0x1d640u32.to_le_bytes());
        validate_preloader(&bytes, &write).unwrap();
        bytes[0x220] ^= 1;
        assert!(validate_preloader(&bytes, &write).is_err());
    }
    #[test]
    fn read_back_mismatch_stops_verification() {
        let mut source = Images(vec![vec![1; 512]]);
        let mut events = Events(vec![]);
        let mut sink = VerifySink {
            source: &mut source,
            observer: &mut events,
            image: 0,
            source_offset: 0,
            compared: 0,
            base: 512,
            total: 1024,
            mapping: "test".into(),
            region: Region::User,
            strict: true,
            matches: true,
        };
        let error =
            pollster::block_on(da::BackupSink::chunk(&mut sink, &[2; 512], 512, 512)).unwrap_err();
        assert!(error.contains("Read-back verification failed"));
        assert!(events.0.is_empty());
    }
}
