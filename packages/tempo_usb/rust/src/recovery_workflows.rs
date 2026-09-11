//! Recovery-backed archive/package workflows; shares validation with DA
//! workflows.
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use serde_json::{Value, json};

use crate::{
    Result, firmware,
    package::PreparedPackage,
    recovery::{Client, Progress, Region, UsbBulk},
};
fn emit(v: Value) {
    println!("{v}");
}
fn resource(name: &str) -> Result<PathBuf> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let beside = exe.parent().unwrap();
    let mut roots = vec![beside.join("recovery")];
    // A macOS bundle keeps data out of Contents/MacOS, in Contents/Resources.
    if let Some(contents) = beside.parent() {
        roots.push(contents.join("Resources").join("recovery"));
    }
    for p in std::env::current_dir()
        .map_err(|e| e.to_string())?
        .ancestors()
    {
        roots.push(p.join("build/recovery"));
    }
    roots.into_iter().map(|r|r.join(name)).find(|p|p.is_file()).ok_or_else(||format!("Tempo Recovery resource {name} is missing. Build platform/recovery or install the complete Toolbox bundle."))
}
fn connect(cancel: Arc<AtomicBool>) -> Result<Client<UsbBulk>> {
    let start = Instant::now();
    let mut booted = false;
    emit(json!({"event":"waiting","message":"Waiting for Tempo Recovery or a powered-off Y2…"}));
    while start.elapsed() < Duration::from_secs(300) {
        if cancel.load(Ordering::Relaxed) {
            return Err("Operation cancelled".into());
        }
        match UsbBulk::open() {
            Ok(port) => return Ok(Client::new(port)),
            Err(e) if e.contains("found 0") => {}
            Err(e) => return Err(e),
        }
        if !booted {
            let mut devices = crate::native::candidates()?;
            if devices.len() > 1 {
                return Err("Multiple boot devices connected".into());
            }
            if let Some(device) = devices.pop() {
                let da = std::fs::read(resource("ramboot-DA.bin")?).map_err(|e| e.to_string())?;
                let payload = std::fs::read(resource("payload.bin")?).map_err(|e| e.to_string())?;
                let preloader =
                    std::fs::read(resource("preloader.bin")?).map_err(|e| e.to_string())?;
                let emi = crate::emi::Emi::parse(&preloader)?;
                let (mut port, _) = crate::native::NativePort::open(device, cancel.clone())?;
                let layout = port.layout.clone();
                let chip = pollster::block_on(crate::probe(&mut port, &layout))?;
                let agent = crate::da::Agent::parse(&da, &chip)?;
                emit(json!({"event":"waiting","message":"Starting Tempo Recovery in RAM…"}));
                port.set_transfer_timeout(Duration::from_secs(10));
                let mut last = Instant::now();
                pollster::block_on(crate::da::boot_ram_with_progress(
                    &mut port,
                    &agent,
                    Some(&emi),
                    &payload,
                    &mut |message, completed, total| {
                        if completed == 0
                            || completed == total
                            || last.elapsed() >= Duration::from_millis(150)
                        {
                            emit(
                                json!({"event":"recovery-boot-progress", "message":message, "completed":completed, "total":total}),
                            );
                            last = Instant::now();
                        }
                    },
                ))?;
                emit(
                    json!({"event":"recovery-starting", "message":"Starting Tempo Recovery; waiting for USB…"}),
                );
                use crate::Transport;
                let mut marker = Vec::new();
                while marker.len() < 4 {
                    let bytes = pollster::block_on(port.read(4 - marker.len()))?;
                    if bytes.is_empty() {
                        return Err("Recovery RAM entry did not acknowledge".into());
                    }
                    marker.extend(bytes);
                }
                if marker != b"TRDY" {
                    return Err("Recovery RAM entry failed".into());
                }
                booted = true;
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err("No Tempo Recovery device appeared".into())
}
fn geometry(client: &mut Client<UsbBulk>) -> Result<()> {
    let info = client.info()?;
    for (id, size) in [
        (0, firmware::Y2_USER_SIZE),
        (1, firmware::Y2_BOOT_SIZE),
        (2, firmware::Y2_BOOT_SIZE),
    ] {
        let valid = info["regions"].as_array().is_some_and(|r| {
            r.iter()
                .any(|r| r["id"] == id && r["size"].as_u64() == Some(size))
        });
        if !valid {
            return Err("Recovery storage geometry does not match the Y2".into());
        }
    }
    Ok(())
}
fn report(event: &str, base: u64, total: u64, p: Progress) {
    emit(
        json!({"event":event,"completed":base+p.completed,"total":total,"bytes_per_second":p.bytes_per_second}),
    );
}
struct Compare<'a> {
    file: &'a mut crate::sparse_image::ImageSource,
    matches: bool,
}
impl Write for Compare<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let mut expected = vec![0; bytes.len()];
        self.file.read_exact(&mut expected)?;
        self.matches &= expected == bytes;
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
fn finish_device(client: &mut Client<UsbBulk>, reboot: bool) -> String {
    if !reboot {
        return "The player remains in Tempo Recovery.".into();
    }
    match client.reboot() {
        Ok(true) => "Restarting the player.".into(),
        result => {
            let reason = match result {
                Ok(false) => "This recovery version cannot reboot remotely".to_string(),
                Err(e) => e,
                _ => unreachable!(),
            };
            emit(
                json!({"event":"warning","message":format!("{reason}. Transfer succeeded; restart the player manually.")}),
            );
            "Transfer succeeded; restart the player manually.".into()
        }
    }
}
pub fn run(args: &[String], cancel: Arc<AtomicBool>) -> Result<Value> {
    if args == ["probe"] {
        let mut client = connect(cancel)?;
        geometry(&mut client)?;
        return Ok(
            json!({"event":"result", "message":"Tempo Recovery ready; storage geometry verified without writes."}),
        );
    }
    if args.len() < 2 {
        return Err("Expected recovery operation and file".into());
    }
    let operation = args[0].as_str();
    let path = Path::new(&args[1]);
    let allow = args[2..].iter().any(|a| a == "--allow-preloader");
    let verify_write = !args[2..].iter().any(|a| a == "--no-verify");
    let reboot = !args[2..].iter().any(|a| a == "--no-reboot");
    let resume = args[2..].iter().any(|a| a == "--resume");
    if args[2..].iter().any(|a| {
        a != "--allow-preloader" && a != "--resume" && a != "--no-verify" && a != "--no-reboot"
    }) || !matches!(operation, "backup" | "restore" | "flash")
    {
        return Err("Invalid recovery workflow arguments".into());
    }
    if operation == "backup" {
        if allow || resume || !verify_write {
            return Err("Write flags are not valid for backup".into());
        }
        if path.exists() {
            return Err("Backup output already exists".into());
        }
        let mut client = connect(cancel.clone())?;
        geometry(&mut client)?;
        // Preserve the existing continuous gzip layout, including its reserved
        // gap.
        let file = File::options()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|e| e.to_string())?;
        let mut gzip = flate2::write::GzEncoder::new(file, flate2::Compression::fast());
        let total = crate::restore::CONTINUOUS_SIZE;
        let mut base = 0;
        emit(json!({"event":"backup-started","bytes":total}));
        for (region, len) in [
            (Region::Boot0, firmware::Y2_BOOT_SIZE),
            (Region::Boot1, firmware::Y2_BOOT_SIZE),
            (Region::User, firmware::Y2_USER_SIZE),
        ] {
            if matches!(region, Region::User) {
                let zeros = vec![0; crate::restore::RPMB_SIZE as usize];
                gzip.write_all(&zeros).map_err(|e| e.to_string())?;
                base += zeros.len() as u64;
            }
            client.set_context(
                "Backing up player",
                match region {
                    Region::Boot0 => "Region 1/3 - boot0",
                    Region::Boot1 => "Region 2/3 - boot1",
                    Region::User => "Region 3/3 - user data",
                },
            )?;
            client.read_region(region, 0, len, &mut gzip, &cancel, &mut |p| {
                report("backup-progress", base, total, p)
            })?;
            base += len;
        }
        emit(json!({"event":"backup-finalizing","completed":total,"total":total}));
        gzip.finish()
            .map_err(|e| e.to_string())?
            .sync_all()
            .map_err(|e| e.to_string())?;
        let disposition = finish_device(&mut client, reboot);
        return Ok(
            json!({"event":"result","message":format!("Backup complete. {disposition}"),"backup":true,"bytes":total,"backup_file":path.display().to_string(),"report":{"compatible_chip":true},"format":"raw-emmc-gzip"}),
        );
    }
    emit(
        json!({"event":"firmware-prepare-started","message":"Checking input data integrity before connecting to USB…"}),
    );
    let mut package = if operation == "restore" {
        crate::restore::prepare(path, &cancel, |completed, total| {
            emit(json!({"event":"firmware-prepare-progress","completed":completed,"total":total}))
        })?
    } else {
        PreparedPackage::prepare(path, |completed, total| {
            emit(json!({"event":"firmware-prepare-progress","completed":completed,"total":total}))
        })?
    };
    let mut plan = package.manifest.write_plan(allow)?;
    if plan.is_empty() {
        return Err("No writable ranges selected".into());
    }
    plan.sort_by_key(|w| w.region == firmware::Region::Boot1);
    let boot: Vec<_> = plan
        .iter()
        .filter(|w| w.region == firmware::Region::Boot1)
        .collect();
    if boot.len() > 1 {
        return Err("Preloader requires exactly one mapping".into());
    }
    for w in boot {
        let file = &mut package.files[w.image];
        file.seek(SeekFrom::Start(w.source_offset))
            .map_err(|e| e.to_string())?;
        let mut header = [0; 0x1000];
        file.read_exact(&mut header).map_err(|e| e.to_string())?;
        firmware::validate_preloader(&header, w)?;
    }
    let total = plan.iter().map(|w| w.length).sum::<u64>();
    let large_partitions = plan
        .iter()
        .filter(|w| w.length >= 128 * 1024 * 1024)
        .count();
    let mut client = connect(cancel.clone())?;
    geometry(&mut client)?;
    let mut base = 0;
    emit(
        json!({"event":"flash-started","completed":0,"total":total,"bytes":total,"preloader_enabled":allow,"large_partition_count":large_partitions}),
    );
    let partitions = plan.len();
    for (index, w) in plan.into_iter().enumerate() {
        let region = match w.region {
            firmware::Region::Boot1 => Region::Boot0,
            firmware::Region::Boot2 => Region::Boot1,
            firmware::Region::User => Region::User,
        };
        let mapping = package.manifest.images[w.image].writes[w.mapping]
            .name
            .clone();
        let progress = |phase: &str, completed: u64, speed: f64| {
            emit(json!({"event":"flash-progress", "phase":phase,
                "region":w.region, "mapping":mapping, "completed":if phase == "checking" {base} else {completed},
                "task_completed":completed-base,"task_total":w.length,"task_index":index+1,"task_count":partitions,"large_partition_count":large_partitions,
                "total":total, "bytes_per_second":speed}));
        };
        let file = &mut package.files[w.image];
        if resume {
            client.set_context(
                &format!("Checking {mapping}"),
                &format!(
                    "Partition {}/{} - comparing saved data",
                    index + 1,
                    partitions
                ),
            )?;
            file.seek(SeekFrom::Start(w.source_offset))
                .map_err(|e| e.to_string())?;
            let mut compare = Compare {
                file,
                matches: true,
            };
            client.read_region(
                region,
                w.target_offset,
                w.length,
                &mut compare,
                &cancel,
                &mut |p| progress("checking", base + p.completed, p.bytes_per_second),
            )?;
            if compare.matches {
                base += w.length;
                emit(
                    json!({"event":"flash-progress","completed":base,"total":total,"skipped":true}),
                );
                continue;
            }
        }
        file.seek(SeekFrom::Start(w.source_offset))
            .map_err(|e| e.to_string())?;
        client.set_context(
            &format!(
                "{} {mapping}",
                if operation == "restore" {
                    "Restoring"
                } else {
                    "Flashing"
                }
            ),
            &format!(
                "Partition {}/{} - {}",
                index + 1,
                partitions,
                if verify_write {
                    "write + readback verification"
                } else {
                    "writing data"
                }
            ),
        )?;
        progress("writing", base, 0.0);
        client.write_region(
            region,
            w.target_offset,
            w.length,
            file,
            allow,
            verify_write,
            &cancel,
            &mut |p| progress("writing", base + p.completed, p.bytes_per_second),
        )?;
        base += w.length;
    }
    let disposition = finish_device(&mut client, reboot);
    Ok(
        json!({"event":"result","flashed":true,"report":{"compatible_chip":true,"flash_verified":verify_write,"storage_written":true},"verified_bytes":if verify_write {total} else {0},"message":format!("{} {disposition}", if verify_write {"Transfer verified."} else {"Transfer complete without readback verification."})}),
    )
}
