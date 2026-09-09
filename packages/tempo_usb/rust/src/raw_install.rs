//! Native guarded BOOTIMG/LOGO installation, using the shared firmware writer.
//! Address translation must pass the real-device write test before enabling
//! writes.
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

use sha2::{Digest, Sha256};

use crate::{
    Result, Transport, da, firmware as fw, partitions,
    raw_image::{self, Target},
};

/// Deliberately closed until the physical USER write address is hardware
/// verified.
pub const HARDWARE_WRITE_VALIDATED: bool = false;

pub struct Prepared {
    pub info: raw_image::Info,
    pub sha256: String,
    bytes: Vec<u8>,
    target: Target,
}
impl Prepared {
    /// Bounded, immutable staging: later changes to the input file cannot
    /// change writes.
    pub fn open(target: Target, path: &Path) -> Result<Self> {
        if matches!(target, Target::Boot1) {
            return Err(
                "Raw installation permits only BOOTIMG and LOGO; use guarded firmware for BOOT1"
                    .into(),
            );
        }
        let file = File::open(path).map_err(|e| e.to_string())?;
        if !file.metadata().map_err(|e| e.to_string())?.is_file() {
            return Err("Raw input must be a regular file".into());
        }
        let mut bytes = Vec::new();
        file.take(target.capacity() as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        Self::from_bytes(target, bytes)
    }
    fn from_bytes(target: Target, mut bytes: Vec<u8>) -> Result<Self> {
        if matches!(target, Target::Boot1) {
            return Err("Raw BOOT1 installation is not supported".into());
        }
        let info = raw_image::inspect(target, &bytes)?;
        let sha256 = hash(&bytes);
        bytes.resize(info.padded_size, 0);
        Ok(Self {
            info,
            sha256,
            bytes,
            target,
        })
    }
    fn name(&self) -> &'static str {
        match self.target {
            Target::Bootimg => "BOOTIMG",
            Target::Logo => "LOGO",
            Target::Boot1 => unreachable!(),
        }
    }
    fn manifest(&self, address: u64) -> Result<fw::Manifest> {
        let manifest = fw::Manifest {
            format: fw::FORMAT.into(),
            format_version: fw::FORMAT_VERSION,
            device: fw::Device {
                id: "innioasis-y2".into(),
                hardware_code: 0x6582,
                hardware_subcode: 0x8a00,
                storage: fw::Storage {
                    boot1: fw::Y2_BOOT_SIZE,
                    boot2: fw::Y2_BOOT_SIZE,
                    user: fw::Y2_USER_SIZE,
                },
            },
            firmware: fw::Firmware {
                icon: None,
                commit: None,
                id: "guarded-raw".into(),
                name: format!("Guarded {}", self.name()),
                version: self.sha256.clone(),
            },
            images: vec![fw::Image {
                file: "images/raw.img".into(),
                size: self.bytes.len() as u64,
                sha256: hash(&self.bytes),
                writes: vec![fw::Write {
                    name: self.name().into(),
                    region: fw::Region::User,
                    source_offset: 0,
                    target_offset: address,
                    length: self.bytes.len() as u64,
                }],
            }],
        };
        manifest.validate()?;
        Ok(manifest)
    }
}
impl fw::FirmwareSource for Prepared {
    async fn chunk(&mut self, image: usize, offset: u64, length: usize) -> Result<Vec<u8>> {
        if image != 0 {
            return Err("Unknown raw image".into());
        }
        let offset = usize::try_from(offset).map_err(|_| "Raw source offset overflow")?;
        let end = offset
            .checked_add(length)
            .ok_or("Raw source length overflow")?;
        self.bytes
            .get(offset..end)
            .map(|b| b.to_vec())
            .ok_or("Raw source range exceeds staged image".into())
    }
}
fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Reserve private, non-overwriting safety files before USB is opened. Failed
/// or cancelled captures remain on disk as incomplete evidence; they are never
/// used as resume tickets. LOGO additionally gets a directly installable
/// trimmed image.
pub struct SafetyBackup {
    file: File,
    pub path: PathBuf,
    logo: Option<(File, PathBuf)>,
}
impl SafetyBackup {
    pub fn create(path: &Path, target: Target) -> Result<Self> {
        if matches!(target, Target::Boot1) {
            return Err("Raw BOOT1 is not supported".into());
        }
        let open = |p: &Path| -> Result<File> {
            let mut options = OpenOptions::new();
            options.read(true).write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            options
                .open(p)
                .map_err(|e| format!("Cannot reserve safety backup {}: {e}", p.display()))
        };
        let file = open(path)?;
        let logo = if matches!(target, Target::Logo) {
            let mut name = path.as_os_str().to_owned();
            name.push(".logo.img");
            let path = PathBuf::from(name);
            Some((open(&path)?, path))
        } else {
            None
        };
        // Persist the directory entry as well as file contents before any
        // write.
        #[cfg(unix)]
        File::open(
            path.parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(Path::new(".")),
        )
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())?;
        Ok(Self {
            file,
            path: path.into(),
            logo,
        })
    }
    fn save(&mut self, bytes: &[u8], target: Target) -> Result<String> {
        use std::io::{Seek, SeekFrom};
        if self.file.metadata().map_err(|e| e.to_string())?.len() != 0 {
            return Err("Safety backup has already been used".into());
        }
        self.file
            .write_all(bytes)
            .and_then(|_| self.file.sync_all())
            .map_err(|e| e.to_string())?;
        self.file
            .seek(SeekFrom::Start(0))
            .map_err(|e| e.to_string())?;
        let mut saved = Vec::new();
        (&mut self.file)
            .take(bytes.len() as u64 + 1)
            .read_to_end(&mut saved)
            .map_err(|e| e.to_string())?;
        let digest = hash(bytes);
        if saved.len() != bytes.len() || hash(&saved) != digest {
            return Err("Safety backup read-back hash mismatch".into());
        }
        if let Some((file, _)) = &mut self.logo {
            let length = current_header(target, bytes, false)?;
            file.write_all(&bytes[..length])
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
            file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
            let mut saved = Vec::new();
            file.take(length as u64 + 1)
                .read_to_end(&mut saved)
                .map_err(|e| e.to_string())?;
            if saved != bytes[..length] {
                return Err("Restoreable LOGO backup read-back mismatch".into());
            }
        }
        Ok(digest)
    }
}
fn current_header(target: Target, bytes: &[u8], force_boot: bool) -> Result<usize> {
    match target {
        Target::Bootimg => {
            if bytes.get(..8) != Some(b"ANDROID!") && !force_boot {
                return Err(
                    "Current BOOTIMG lacks ANDROID!; explicit --force-boot-header is required"
                        .into(),
                );
            }
            Ok(target.capacity())
        }
        Target::Logo => {
            let word = |offset| -> Result<usize> {
                Ok(u32::from_le_bytes(
                    bytes
                        .get(offset..offset + 4)
                        .ok_or("Truncated current LOGO header")?
                        .try_into()
                        .unwrap(),
                ) as usize)
            };
            if bytes.get(..4) != Some(&[0x88, 0x16, 0x88, 0x58])
                || bytes
                    .get(8..40)
                    .is_none_or(|name| name.split(|b| *b == 0).next() != Some(b"LOGO".as_slice()))
            {
                return Err("Current LOGO has no valid MediaTek LOGO header".into());
            }
            let body = word(4)?;
            let count = word(512)?;
            if body <= 8
                || body + 512 > target.capacity()
                || !(1..256).contains(&count)
                || word(516)? != body
            {
                return Err("Current LOGO body/count/total is implausible".into());
            }
            Ok(body + 512)
        }
        Target::Boot1 => Err("Raw BOOT1 is not supported".into()),
    }
}
struct Buffer {
    bytes: Vec<u8>,
    limit: usize,
}
impl da::BackupSink for Buffer {
    async fn chunk(&mut self, bytes: &[u8], _: u64, _: u64) -> Result<()> {
        if self
            .bytes
            .len()
            .checked_add(bytes.len())
            .is_none_or(|n| n > self.limit)
        {
            return Err("Oversized safety read".into());
        }
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
}
#[derive(Debug, serde::Serialize)]
pub struct Outcome {
    pub target: String,
    pub continuous_address: u64,
    pub physical_user_address: u64,
    pub safety_path: PathBuf,
    pub safety_sha256: String,
    pub restoreable_logo_path: Option<PathBuf>,
    pub source_sha256: String,
    pub storage_written: bool,
}

/// Read guards and full safety backup run even in dry-run mode. Failure after a
/// write must leave the DA available for recovery: this API never reboots.
pub async fn install(
    port: &mut impl Transport,
    geometry: &da::Geometry,
    source: &mut Prepared,
    safety: &mut SafetyBackup,
    observer: &mut impl fw::FlashObserver,
    dry_run: bool,
    force_boot_header: bool,
) -> Result<Outcome> {
    if !dry_run && !HARDWARE_WRITE_VALIDATED {
        return Err("Raw writes disabled pending physical USER write-address hardware validation; --dry-run remains available".into());
    }
    if force_boot_header && !matches!(source.target, Target::Bootimg) {
        return Err("--force-boot-header is only valid for BOOTIMG".into());
    }
    if !geometry.is_y2() {
        return Err("Raw installation requires exact Y2 geometry".into());
    }
    if safety.logo.is_some() != matches!(source.target, Target::Logo) {
        return Err("Safety backup target does not match source".into());
    }
    let parts = partitions::vendor_scatter()?;
    let anchor = partitions::locate(port, geometry, &parts).await?;
    let capacity = geometry.image_size()?;
    let (address, size) = partitions::range(source.name(), &anchor, &parts, capacity)?;
    if size != source.target.capacity() as u64 {
        return Err("Anchored partition has unexpected size".into());
    }
    let prefix = da::hardware_read_address(geometry, 8, 0, 512)?;
    let physical = address
        .checked_sub(prefix)
        .ok_or("Anchored target overlaps protected hardware regions")?;
    if da::hardware_read_address(geometry, 8, physical, size)? != address {
        return Err("Raw target address translation mismatch".into());
    }
    let manifest = source.manifest(physical)?;
    let mut header = Buffer {
        bytes: Vec::new(),
        limit: 4096,
    };
    da::read_region(port, 8, capacity, address, 4096, &mut header).await?;
    current_header(source.target, &header.bytes, force_boot_header)?;
    let mut backup = Buffer {
        bytes: Vec::new(),
        limit: size as usize,
    };
    da::read_region(port, 8, capacity, address, size, &mut backup).await?;
    if backup.bytes.len() != size as usize
        || backup.bytes.get(..4096) != Some(header.bytes.as_slice())
    {
        return Err("Safety capture length/header changed; refusing write".into());
    }
    let safety_sha256 = safety.save(&backup.bytes, source.target)?;
    observer
        .progress(fw::FlashProgress {
            phase: "safety-backup-verified",
            completed: size,
            total: size,
            mapping: Some(source.name().into()),
            region: Some(fw::Region::User),
        })
        .await?;
    if !dry_run {
        fw::flash_verified(port, geometry, &manifest, source, observer, false)
            .await
            .map_err(|error| {
                format!(
                    "{error}. Safety backup retained at {}; device left in DA for recovery",
                    safety.path.display()
                )
            })?;
    }
    Ok(Outcome {
        target: source.name().into(),
        continuous_address: address,
        physical_user_address: physical,
        safety_path: safety.path.clone(),
        safety_sha256,
        restoreable_logo_path: safety.logo.as_ref().map(|(_, p)| p.clone()),
        source_sha256: source.sha256.clone(),
        storage_written: !dry_run,
    })
}

#[cfg(test)]
mod tests {
    use std::{
        collections::VecDeque,
        sync::atomic::{AtomicU64, Ordering},
    };

    use super::*;
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!(
                "tempo-raw-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn boot() -> Vec<u8> {
        let mut b = vec![0; 4096];
        b[..8].copy_from_slice(b"ANDROID!");
        b[8..12].copy_from_slice(&1u32.to_le_bytes());
        b[36..40].copy_from_slice(&2048u32.to_le_bytes());
        b
    }
    fn geometry() -> da::Geometry {
        da::Geometry {
            user: fw::Y2_USER_SIZE,
            boot1: fw::Y2_BOOT_SIZE,
            boot2: fw::Y2_BOOT_SIZE,
            rpmb: 0x80000,
        }
    }
    enum Step {
        Write(Vec<u8>),
        Read(Vec<u8>),
    }
    struct Replay(VecDeque<Step>);
    impl Transport for Replay {
        async fn write(&mut self, b: &[u8]) -> Result<()> {
            match self.0.pop_front() {
                Some(Step::Write(expected)) if expected == b => Ok(()),
                _ => Err(format!("Unexpected command {b:02x?}")),
            }
        }
        async fn read(&mut self, n: usize) -> Result<Vec<u8>> {
            match self.0.pop_front() {
                Some(Step::Read(mut b)) => {
                    if b.len() > n {
                        let tail = b.split_off(n);
                        self.0.push_front(Step::Read(tail));
                    }
                    Ok(b)
                }
                _ => Err("Unexpected read".into()),
            }
        }
        async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
            Err("Unexpected control".into())
        }
    }
    fn read(steps: &mut VecDeque<Step>, address: u64, bytes: Vec<u8>) {
        if bytes.len() > 0x100000 {
            for (index, chunk) in bytes.chunks(0x100000).enumerate() {
                read(steps, address + (index as u64 * 0x100000), chunk.to_vec());
            }
            return;
        }
        use Step::*;
        steps.extend([
            Write(vec![0x72]),
            Read(vec![0x5a]),
            Read(vec![1]),
            Write(vec![0x60]),
            Read(vec![0x5a]),
            Write(vec![8]),
            Read(vec![0x5a]),
            Write(vec![0xd6]),
            Write(vec![0x0c]),
            Write(vec![2]),
            Write(address.to_be_bytes().to_vec()),
            Write((bytes.len() as u64).to_be_bytes().to_vec()),
            Read(vec![0x5a]),
            Write(0x100000u32.to_be_bytes().to_vec()),
        ]);
        for chunk in bytes.chunks(0x100000) {
            let sum = chunk.iter().fold(0u16, |s, b| s.wrapping_add(*b as u16));
            steps.extend([
                Read(chunk.to_vec()),
                Read(sum.to_be_bytes().to_vec()),
                Write(vec![0x5a]),
            ]);
        }
    }
    fn anchored() -> VecDeque<Step> {
        let mut steps = VecDeque::new();
        let parts = partitions::vendor_scatter().unwrap();
        let ebr = parts.iter().find(|p| p.name == "EBR1").unwrap().physical;
        for base in [0, 0xb80000, 0x1400000u64] {
            for offset in [0, ebr] {
                let mut bytes = vec![0; 512];
                if base == 0x1400000 {
                    bytes[510..].copy_from_slice(&[0x55, 0xaa]);
                    if offset == 0 {
                        bytes[450] = 0x83;
                        bytes[454] = 1;
                    }
                }
                read(&mut steps, base + offset, bytes);
            }
        }
        steps
    }
    struct Observer(Vec<&'static str>);
    impl fw::FlashObserver for Observer {
        async fn progress(&mut self, e: fw::FlashProgress) -> Result<()> {
            self.0.push(e.phase);
            Ok(())
        }
    }
    #[test]
    fn dry_run_requires_complete_backup_and_maps_observed_continuous_address() {
        let tmp = Temp::new();
        let path = tmp.0.join("safety.img");
        let mut source = Prepared::from_bytes(Target::Bootimg, boot()).unwrap();
        let mut safety = SafetyBackup::create(&path, Target::Bootimg).unwrap();
        let mut bytes = boot();
        bytes.resize(Target::Bootimg.capacity(), 0xab);
        let mut steps = anchored();
        read(&mut steps, 0x3180000, bytes[..4096].to_vec());
        read(&mut steps, 0x3180000, bytes.clone());
        let mut port = Replay(steps);
        let mut observer = Observer(vec![]);
        let result = pollster::block_on(install(
            &mut port,
            &geometry(),
            &mut source,
            &mut safety,
            &mut observer,
            true,
            false,
        ))
        .unwrap();
        assert_eq!(result.physical_user_address, 0x2900000);
        assert!(!result.storage_written);
        assert_eq!(result.safety_sha256, hash(&bytes));
        assert_eq!(std::fs::read(path).unwrap(), bytes);
        assert!(port.0.is_empty());
        assert_eq!(observer.0, vec!["safety-backup-verified"]);
    }
    #[test]
    fn unsafe_current_header_stops_before_backup_and_never_writes() {
        let tmp = Temp::new();
        let path = tmp.0.join("safety.img");
        let mut source = Prepared::from_bytes(Target::Bootimg, boot()).unwrap();
        let mut safety = SafetyBackup::create(&path, Target::Bootimg).unwrap();
        let mut steps = anchored();
        read(&mut steps, 0x3180000, vec![0; 4096]);
        let mut port = Replay(steps);
        let error = pollster::block_on(install(
            &mut port,
            &geometry(),
            &mut source,
            &mut safety,
            &mut Observer(vec![]),
            true,
            false,
        ))
        .unwrap_err();
        assert!(error.contains("ANDROID!"));
        assert!(port.0.is_empty());
        assert_eq!(std::fs::metadata(path).unwrap().len(), 0);
    }
    #[test]
    fn unvalidated_write_gate_precedes_any_usb_command() {
        if HARDWARE_WRITE_VALIDATED {
            return;
        }
        let tmp = Temp::new();
        let mut source = Prepared::from_bytes(Target::Bootimg, boot()).unwrap();
        let mut safety = SafetyBackup::create(&tmp.0.join("safety"), Target::Bootimg).unwrap();
        let mut port = Replay(VecDeque::new());
        let error = pollster::block_on(install(
            &mut port,
            &geometry(),
            &mut source,
            &mut safety,
            &mut Observer(vec![]),
            false,
            false,
        ))
        .unwrap_err();
        assert!(error.contains("disabled"));
    }
    #[test]
    fn logo_backup_preserves_entire_partition_and_restoreable_image() {
        let tmp = Temp::new();
        let path = tmp.0.join("safety");
        let logo = include_bytes!("../../../../platform/firmware/stock/logo.bin");
        let mut partition = logo.to_vec();
        partition.resize(Target::Logo.capacity(), 0xa5);
        let mut safety = SafetyBackup::create(&path, Target::Logo).unwrap();
        safety.save(&partition, Target::Logo).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), partition);
        let restored = std::fs::read(safety.logo.as_ref().unwrap().1.clone()).unwrap();
        assert_eq!(restored, logo);
        assert!(raw_image::inspect(Target::Logo, &restored).is_ok());
        assert!(safety.save(&partition, Target::Logo).is_err());
        assert!(SafetyBackup::create(&path, Target::Logo).is_err());
    }
    #[test]
    fn force_only_relaxes_existing_boot_magic_and_never_source_or_logo_guards() {
        assert!(current_header(Target::Bootimg, &[0; 4096], true).is_ok());
        assert!(current_header(Target::Logo, &[0; 4096], true).is_err());
        assert!(Prepared::from_bytes(Target::Bootimg, vec![0; 4096]).is_err());
        assert!(Prepared::from_bytes(Target::Boot1, vec![0; 0x400000]).is_err());
    }
    #[test]
    fn source_is_bounded_immutable_and_manifest_only_maps_user() {
        let tmp = Temp::new();
        let path = tmp.0.join("boot.img");
        std::fs::write(&path, boot()).unwrap();
        let mut source = Prepared::open(Target::Bootimg, &path).unwrap();
        std::fs::write(&path, vec![0; 4096]).unwrap();
        assert_eq!(
            pollster::block_on(fw::FirmwareSource::chunk(&mut source, 0, 0, 8)).unwrap(),
            b"ANDROID!"
        );
        let manifest = source.manifest(0x2900000).unwrap();
        let plan = manifest.write_plan(false).unwrap();
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].region, fw::Region::User);
        assert!(source.manifest(fw::Y2_USER_SIZE).is_err());
        let oversized = File::create(&path).unwrap();
        oversized
            .set_len(Target::Logo.capacity() as u64 + 1)
            .unwrap();
        assert!(Prepared::open(Target::Logo, &path).is_err());
    }
}
