#[cfg(not(target_arch = "wasm32"))]
mod control;

#[cfg(not(target_arch = "wasm32"))]
fn read_cleanup_result<T>(
    read: Result<T, String>,
    cleanup: Result<(), String>,
) -> Result<T, String> {
    match (read, cleanup) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(error), Ok(())) => Err(error),
        (Ok(_), Err(error)) => Err(format!(
            "Read completed, but the Y2 could not be reset: {error}"
        )),
        (Err(error), Err(cleanup)) => Err(format!(
            "{error}. The Y2 also could not be reset: {cleanup}"
        )),
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod read_cleanup_tests {
    use super::read_cleanup_result;
    #[test]
    fn does_not_hide_reset_failure_behind_cancellation() {
        let error =
            read_cleanup_result::<()>(Err("cancelled".into()), Err("DA busy".into())).unwrap_err();
        assert!(error.contains("cancelled"));
        assert!(error.contains("DA busy"));
        assert!(
            read_cleanup_result(Ok(7), Err("timeout".into()))
                .unwrap_err()
                .contains("Read completed")
        );
        assert_eq!(read_cleanup_result(Ok(7), Ok(())), Ok(7));
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn main() {
    use std::{
        io::Write,
        path::{Path, PathBuf},
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        time::{Duration, Instant},
    };

    use serde_json::json;
    use tempo_installer::{da, firmware, native, package, probe};
    let cancelled = Arc::new(AtomicBool::new(false));
    // Cooperative stdin works on every desktop platform. In particular,
    // Windows TerminateProcess cannot run the USB/durable-output cleanup.
    let control_flag = cancelled.clone();
    if let Err(error) = std::thread::Builder::new()
        .name("tempo-usb-control".into())
        .spawn(move || {
            if let Err(error) = control::read_cancellation(std::io::stdin().lock(), &control_flag) {
                eprintln!("Cancellation control input closed: {error}");
            }
        })
    {
        eprintln!("Could not start cancellation control: {error}");
        std::process::exit(1);
    }
    // Preserve terminal and older caller behavior on Unix. Do not rely on
    // Windows CRT signal handlers for cancellation initiated by another
    // process.
    #[cfg(unix)]
    for signal in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        if let Err(error) = signal_hook::flag::register(signal, cancelled.clone()) {
            eprintln!("Could not register cancellation handler: {error}");
            std::process::exit(1);
        }
    }
    struct FileSink(std::fs::File);
    impl da::BackupSink for FileSink {
        async fn chunk(&mut self, bytes: &[u8], completed: u64, total: u64) -> Result<(), String> {
            self.0.write_all(bytes).map_err(|e| e.to_string())?;
            println!(
                "{}",
                json!({"event":"progress","completed":completed,"total":total})
            );
            Ok(())
        }
    }
    struct GzipSink(flate2::write::GzEncoder<std::fs::File>);
    impl da::BackupSink for GzipSink {
        async fn chunk(&mut self, bytes: &[u8], completed: u64, total: u64) -> Result<(), String> {
            self.0.write_all(bytes).map_err(|e| e.to_string())?;
            println!(
                "{}",
                json!({"event":"progress","completed":completed,"total":total})
            );
            Ok(())
        }
    }
    impl GzipSink {
        fn create(path: &Path) -> Result<Self, String> {
            let file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)
                .map_err(|e| e.to_string())?;
            Ok(Self(flate2::write::GzEncoder::new(
                file,
                flate2::Compression::fast(),
            )))
        }
        fn finish(self) -> Result<(), String> {
            let file = self.0.finish().map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())
        }
    }
    struct JsonFlashObserver {
        wrote: bool,
    }
    impl firmware::FlashObserver for JsonFlashObserver {
        async fn progress(&mut self, event: firmware::FlashProgress) -> Result<(), String> {
            self.wrote |= event.phase == "writing";
            println!(
                "{}",
                json!({
                    "event":"flash-progress",
                    "phase":event.phase,
                    "completed":event.completed,
                    "total":event.total,
                    "mapping":event.mapping,
                    "region":event.region,
                })
            );
            Ok(())
        }
    }
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "recovery") {
        let result = tempo_installer::recovery_workflows::run(&args[1..], cancelled.clone());
        match result {
            Ok(event) => println!("{event}"),
            Err(message) => {
                let event = if cancelled.load(Ordering::Relaxed) {
                    "cancelled"
                } else {
                    "error"
                };
                println!("{}", json!({"event":event,"message":message}));
                if event == "error" {
                    std::process::exit(1);
                }
            }
        }
        return;
    }

    let verify_write = if let Some(index) = args.iter().position(|arg| arg == "--no-verify") {
        args.remove(index);
        false
    } else {
        true
    };
    let resume = if let Some(index) = args.iter().position(|arg| arg == "--resume") {
        args.remove(index);
        true
    } else {
        false
    };
    let emi = if let Some(index) = args.iter().position(|arg| arg == "--preloader") {
        if index + 1 >= args.len() {
            eprintln!("--preloader requires a file");
            std::process::exit(2);
        }
        let path = args.remove(index + 1);
        args.remove(index);
        let prepared = std::fs::metadata(&path)
            .map_err(|e| e.to_string())
            .and_then(|meta| {
                if meta.len() > 0x400000 {
                    Err("Preloader exceeds Y2 BOOT1 size".into())
                } else {
                    std::fs::read(&path).map_err(|e| e.to_string())
                }
            })
            .and_then(|bytes| tempo_installer::emi::Emi::parse(&bytes));
        match prepared {
            Ok(emi) => Some(emi),
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(2);
            }
        }
    } else {
        None
    };
    if args.first().map(String::as_str) == Some("inspect-raw") {
        if args.len() != 3 {
            eprintln!("Usage: tempo-usb inspect-raw BOOTIMG|LOGO|BOOT1 FILE");
            std::process::exit(2);
        }
        match tempo_installer::raw_image::Target::parse(&args[1]).and_then(|target| {
            tempo_installer::raw_image::inspect_file(target, Path::new(&args[2]))
        }) {
            Ok(info) => println!("{}", json!({"event":"raw-image-info","image":info})),
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(1);
            }
        }
        return;
    }
    if args.first().map(String::as_str) == Some("preview-spft") {
        match args
            .get(1)
            .ok_or("Missing ROM path".into())
            .and_then(|p| tempo_installer::spft::preview(Path::new(p)))
        {
            Ok(info) => println!("{info}"),
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(1);
            }
        }
        return;
    }
    if args.first().map(String::as_str) == Some("prepare-firmware")
        || args.first().map(String::as_str) == Some("prepare-spft")
    {
        let staging_root = args
            .get(2)
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let result = args.get(1).ok_or("Missing firmware path".to_string()).and_then(|path| {
            let progress = |completed, total| println!("{}",json!({"event":"firmware-prepare-progress","message":"Validating package…","completed":completed,"total":total}));
            let mut prepared = if args[0] == "prepare-spft" {tempo_installer::spft::prepare_in(Path::new(path), &staging_root, progress)?} else {package::PreparedPackage::prepare_in(Path::new(path), &staging_root, progress)?};
            prepared.retain()
        });
        match result {
            Ok(path) => println!("{}", json!({"event":"result", "path":path})),
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(1);
            }
        }
        return;
    }
    let reboot_after_success = !args.iter().any(|a| a == "--no-reboot");
    args.retain(|a| a != "--no-reboot");
    let inspect_firmware = args.first().map(String::as_str) == Some("inspect-firmware");
    if inspect_firmware {
        if args.len() != 2 {
            eprintln!("Usage: tempo-usb inspect-firmware package.y2-firmware");
            std::process::exit(2);
        }
        match package::inspect(Path::new(&args[1])) {
            Ok(info) => {
                let writes = info
                    .manifest
                    .images
                    .iter()
                    .map(|image| image.writes.len())
                    .sum::<usize>();
                let bytes = info
                    .manifest
                    .images
                    .iter()
                    .map(|image| image.size)
                    .sum::<u64>();
                let includes_preloader = info.manifest.images.iter().any(|image| {
                    image
                        .writes
                        .iter()
                        .any(|write| write.region == firmware::Region::Boot1)
                });
                println!(
                    "{}",
                    json!({"event":"firmware-info","firmware":info.manifest.firmware,
                        "images":info.manifest.images.len(),"writes":writes,"bytes":bytes,
                        "includes_preloader":includes_preloader})
                );
                return;
            }
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(1);
            }
        }
    }
    let raw = args.first().map(String::as_str) == Some("flash-raw");
    let mut raw_dry_run = false;
    let mut raw_force_boot = false;
    if raw {
        for (flag, value) in [
            ("--dry-run", &mut raw_dry_run),
            ("--force-boot-header", &mut raw_force_boot),
        ] {
            if let Some(index) = args.iter().position(|arg| arg == flag) {
                args.remove(index);
                *value = true;
            }
        }
    }
    let backup_resume = args.first().map(String::as_str) == Some("backup-resume");
    let fetch = args.first().map(String::as_str) == Some("fetch");
    let diagnose = args.first().map(String::as_str) == Some("partitions");
    let sample = args.first().map(String::as_str) == Some("read-sample");
    let map = args.first().map(String::as_str) == Some("map-sample");
    let backup = args.first().map(String::as_str) == Some("backup");
    let backup_sample = args.first().map(String::as_str) == Some("backup-sample");
    let restore = args.first().map(String::as_str) == Some("restore");
    let flash = args.first().map(String::as_str) == Some("flash");
    if !verify_write && !restore && !flash {
        eprintln!("--no-verify requires restore or flash");
        std::process::exit(2);
    }
    if resume && !restore && !flash {
        eprintln!("--resume requires restore or flash");
        std::process::exit(2);
    }
    let allow_preloader =
        (flash || restore) && args.get(3).map(String::as_str) == Some("--allow-preloader");
    let compressed = backup || backup_sample;
    if !(raw && args.len() == 5
        || backup_resume && args.len() == 4
        || fetch && args.len() == 4
        || diagnose && args.len() == 2
        || sample && args.len() == 3
        || map && args.len() == 3
        || backup && args.len() == 3
        || backup_sample && args.len() == 3
        || (flash || restore) && (args.len() == 3 || args.len() == 4 && allow_preloader)
        || args.first().map(String::as_str) == Some("probe") && args.len() <= 2)
    {
        eprintln!(
            "Usage: tempo-usb flash-raw DA-file BOOTIMG|LOGO IMAGE SAFETY-BACKUP [--dry-run] [--force-boot-header] | probe [wait-seconds] | backup-resume DA-file LEGACY-DIRECTORY OUTPUT.gz | partitions DA-file | fetch DA-file PARTITION output-file | backup DA-file output.img.gz | restore DA-file backup.img.gz-or-directory [--allow-preloader] | flash DA-file package.y2-firmware [--allow-preloader] | inspect-firmware package.y2-firmware | read-sample DA-file output-file | backup-sample DA-file output.img.gz | map-sample DA-file output-directory\nOptional --preloader FILE supplies Y2 BROM EMI. Default probe wait: 30 seconds; DA operations: 300 seconds."
        );
        std::process::exit(2);
    }
    let seconds = match if raw
        || sample
        || map
        || compressed
        || flash
        || restore
        || fetch
        || diagnose
        || backup_resume
    {
        None
    } else {
        args.get(1)
    } {
        None => {
            if raw
                || sample
                || map
                || compressed
                || flash
                || restore
                || fetch
                || diagnose
                || backup_resume
            {
                300
            } else {
                30
            }
        }
        Some(value) => match value.parse::<u64>() {
            Ok(n @ 1..=300) => n,
            _ => {
                eprintln!("wait-seconds must be between 1 and 300");
                std::process::exit(2);
            }
        },
    };
    if fetch {
        if Path::new(&args[3]).exists() {
            eprintln!("Partition output already exists");
            std::process::exit(2);
        }
        let valid = args[2].eq_ignore_ascii_case("boot1")
            || args[2].eq_ignore_ascii_case("boot2")
            || tempo_installer::partitions::vendor_scatter()
                .is_ok_and(|parts| parts.iter().any(|p| p.name.eq_ignore_ascii_case(&args[2])));
        if !valid {
            eprintln!("Unknown partition");
            std::process::exit(2);
        }
    }
    let mut prepared_raw = if raw {
        let prepare = || -> Result<_, String> {
            if !raw_dry_run && !tempo_installer::raw_install::HARDWARE_WRITE_VALIDATED {
                return Err("Raw writes disabled pending physical USER write-address validation; use --dry-run".into());
            }
            let target = tempo_installer::raw_image::Target::parse(&args[2])?;
            if raw_force_boot && !matches!(target, tempo_installer::raw_image::Target::Bootimg) {
                return Err("--force-boot-header requires BOOTIMG".into());
            }
            let source = tempo_installer::raw_install::Prepared::open(target, Path::new(&args[3]))?;
            let safety =
                tempo_installer::raw_install::SafetyBackup::create(Path::new(&args[4]), target)?;
            println!(
                "{}",
                json!({"event":"raw-ready", "image":source.info, "sha256":source.sha256, "safety_path":safety.path, "dry_run":raw_dry_run})
            );
            Ok((source, safety))
        };
        match prepare() {
            Ok(value) => Some(value),
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(1);
            }
        }
    } else {
        None
    };
    let mut prepared_firmware = if flash || restore {
        println!(
            "{}",
            json!({"event":"firmware-prepare-started","message":"Checking and staging the complete firmware package before connecting the Y2."})
        );
        let progress = |completed, total| {
            println!(
                "{}",
                json!({"event":"firmware-prepare-progress","completed":completed,"total":total})
            );
        };
        let prepared = if restore {
            tempo_installer::restore::prepare(Path::new(&args[2]), &cancelled, progress)
        } else {
            package::PreparedPackage::prepare(Path::new(&args[2]), progress)
        };
        match prepared {
            Ok(prepared) => {
                println!(
                    "{}",
                    json!({"event":"firmware-ready","firmware":prepared.manifest.firmware,
                        "message":"Firmware package verified. Connect a powered-off Y2."})
                );
                Some(prepared)
            }
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(1);
            }
        }
    } else {
        None
    };
    let mut recovery = if backup || backup_resume {
        let prepared = if backup {
            tempo_installer::backup_resume::Recovery::create(Path::new(&args[2]))
        } else {
            tempo_installer::backup_resume::Recovery::prepare(
                Path::new(&args[2]),
                Path::new(&args[3]),
                &cancelled,
                |completed, total| {
                    println!(
                        "{}",
                        json!({"event":"backup-prefix-validation","completed":completed,"total":total})
                    )
                },
            )
        };
        match prepared {
            Ok(value) => {
                println!(
                    "{}",
                    json!({"event":"backup-recovery","path":value.root,"message":"Validated recovery directory; it is retained if interrupted."})
                );
                Some(value)
            }
            Err(message) => {
                println!("{}", json!({"event":"error","message":message}));
                std::process::exit(1);
            }
        }
    } else {
        None
    };
    println!(
        "{}",
        json!({"event":"waiting","message":"Connect a powered-off Y2."})
    );
    // Staging may take minutes; the device discovery budget begins afterwards.
    let started = Instant::now();
    let mut completed_backup: Option<(u64, PathBuf)> = None;
    let mut partition_result = None;
    let outcome = (|| -> Result<(), String> {
        loop {
            if cancelled.load(Ordering::Relaxed) {
                return Err("Connection check stopped".into());
            }
            let devices = native::candidates()?;
            if devices.len() > 1 {
                return Err(
                    "Multiple MediaTek boot devices found. Connect only the intended Y2.".into(),
                );
            }
            if let Some(device) = devices.into_iter().next() {
                let (mut port, info) = native::NativePort::open(device, cancelled.clone())?;
                let layout = port.layout.clone();
                let mut report = pollster::block_on(probe(&mut port, &layout))?;
                if raw
                    || sample
                    || map
                    || compressed
                    || flash
                    || restore
                    || fetch
                    || diagnose
                    || backup_resume
                {
                    let bytes = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
                    let agent = da::Agent::parse(&bytes, &report)?;
                    let geometry = pollster::block_on(da::initialize_with_emi(
                        &mut port,
                        &agent,
                        emi.as_ref(),
                    ))?;
                    port.set_transfer_timeout(Duration::from_secs(10));
                    println!("{}", json!({"event":"geometry","geometry":geometry}));
                    if !geometry.is_y2() {
                        return Err("The eMMC geometry does not match an Innioasis Y2".into());
                    }
                    report.y2_verified = true;
                    if raw {
                        let (source, safety) = prepared_raw
                            .as_mut()
                            .expect("Raw source and safety paths prepared before USB");
                        let result = pollster::block_on(tempo_installer::raw_install::install(
                            &mut port,
                            &geometry,
                            source,
                            safety,
                            &mut JsonFlashObserver { wrote: false },
                            raw_dry_run,
                            raw_force_boot,
                        ))?;
                        // Only verified success may reset. Failed writes stay
                        // in DA for recovery.
                        cancelled.store(false, Ordering::Relaxed);
                        pollster::block_on(da::reboot(&mut port))?;
                        partition_result =
                            Some(serde_json::to_value(result).map_err(|e| e.to_string())?);
                    } else if backup || backup_resume {
                        let recovery = recovery
                            .as_mut()
                            .expect("backup prefix prepared before USB");
                        let captured = pollster::block_on(tempo_installer::backup_resume::capture(
                            &mut port, &geometry, recovery,
                        ));
                        cancelled.store(false, Ordering::Relaxed);
                        let reset = if reboot_after_success {
                            pollster::block_on(port.reboot_after_read())
                        } else {
                            Ok(())
                        };
                        read_cleanup_result(captured, reset)?;
                        tempo_installer::backup_resume::finish(
                            recovery,
                            &cancelled,
                            |completed, total| {
                                println!(
                                    "{}",
                                    json!({"event":"backup-finalizing","completed":completed,"total":total})
                                )
                            },
                        )?;
                        completed_backup = Some((geometry.image_size()?, recovery.output.clone()));
                    } else if fetch || diagnose {
                        let operation =
                            pollster::block_on(tempo_installer::partitions::inspect_or_fetch(
                                &mut port,
                                &geometry,
                                if fetch {
                                    Some((&args[2], Path::new(&args[3])))
                                } else {
                                    None
                                },
                            ));
                        cancelled.store(false, Ordering::Relaxed);
                        let reset = if reboot_after_success {
                            pollster::block_on(port.reboot_after_read())
                        } else {
                            Ok(())
                        };
                        let result = read_cleanup_result(operation, reset)?;
                        partition_result = Some(result);
                    } else if flash || restore {
                        let package = prepared_firmware
                            .as_mut()
                            .expect("firmware was prepared before USB capture");
                        let write_bytes = package
                            .manifest
                            .write_plan(allow_preloader)?
                            .iter()
                            .try_fold(0u64, |sum, write| {
                                sum.checked_add(write.length)
                                    .ok_or_else(|| String::from("Flash size overflow"))
                            })?;
                        println!(
                            "{}",
                            json!({"event":"flash-started","bytes":write_bytes,
                                "preloader_enabled":allow_preloader,
                                "message":if verify_write {"Writing firmware with readback verification."} else {"Writing firmware without readback verification."}})
                        );
                        let mut observer = JsonFlashObserver { wrote: false };
                        let transfer = pollster::block_on(firmware::flash_with_options(
                            &mut port,
                            &geometry,
                            &package.manifest.clone(),
                            package,
                            &mut observer,
                            firmware::WriteOptions {
                                allow_preloader,
                                resume,
                                verify_write,
                            },
                        ));
                        cancelled.store(false, Ordering::Relaxed);
                        let reset = if reboot_after_success {
                            pollster::block_on(port.reboot_after_read())
                        } else {
                            Ok(())
                        };
                        let verified_bytes = match transfer {
                            Ok(bytes) => bytes,
                            Err(transfer_error) => {
                                return Err(match reset {
                                    Ok(()) => transfer_error,
                                    Err(reset_error) => format!(
                                        "{transfer_error}. The Y2 also could not be reset: {reset_error}"
                                    ),
                                });
                            }
                        };
                        reset?;
                        report.storage_written = observer.wrote;
                        println!(
                            "{}",
                            json!({"event":"flash-complete","bytes":write_bytes,
                                "verified_work_bytes":verified_bytes,
                                "message":if observer.wrote {if verify_write {"Firmware written, verified, and the Y2 was reset."} else {"Firmware written without readback verification; the Y2 was reset."}}else{"Existing firmware matched every requested range; the Y2 was reset."}})
                        );
                    } else if compressed {
                        let final_path = PathBuf::from(&args[2]);
                        if final_path.exists() {
                            return Err("Backup destination already exists".into());
                        }
                        let partial_path =
                            PathBuf::from(format!("{}.partial", final_path.display()));
                        let full_size = geometry.image_size()?;
                        let total = if backup_sample { 0x2000000 } else { full_size };
                        println!(
                            "{}",
                            json!({"event":"backup-started","total":total,"format":"raw-emmc-gzip"})
                        );
                        let written = (|| -> Result<(), String> {
                            let mut sink = GzipSink::create(&partial_path)?;
                            pollster::block_on(da::read_region(
                                &mut port, 8, total, 0, total, &mut sink,
                            ))?;
                            sink.finish()?;
                            std::fs::rename(&partial_path, &final_path)
                                .map_err(|e| e.to_string())?;
                            Ok(())
                        })();
                        // Stop is cooperative so the DA connection remains
                        // available long enough to issue its reboot command.
                        cancelled.store(false, Ordering::Relaxed);
                        let reset = if reboot_after_success {
                            pollster::block_on(port.reboot_after_read())
                        } else {
                            Ok(())
                        };
                        if let Err(transfer_error) = written {
                            let _ = std::fs::remove_file(&partial_path);
                            return Err(match reset {
                                Ok(()) => transfer_error,
                                Err(reset_error) => format!(
                                    "{transfer_error}. The Y2 also could not be reset: {reset_error}"
                                ),
                            });
                        }
                        reset?;
                        completed_backup = Some((total, final_path.clone()));
                        println!(
                            "{}",
                            json!({"event":"backup-complete","path":final_path,"bytes":total})
                        );
                    } else if sample {
                        let mut sink = FileSink(
                            std::fs::OpenOptions::new()
                                .write(true)
                                .create_new(true)
                                .open(&args[2])
                                .map_err(|e| e.to_string())?,
                        );
                        pollster::block_on(da::read_region(
                            &mut port,
                            8,
                            geometry.user,
                            0,
                            0x2000000,
                            &mut sink,
                        ))?;
                        sink.0.sync_all().map_err(|e| e.to_string())?;
                    } else {
                        std::fs::create_dir(&args[2]).map_err(|e| e.to_string())?;
                        let user_base = geometry.boot1 + geometry.boot2 + geometry.rpmb;
                        let ranges = [
                            ("boot1.bin", 1, geometry.boot1, 0),
                            ("boot2.bin", 2, geometry.boot2, 0),
                            ("linear-boot1.bin", 8, user_base + geometry.user, 0),
                            (
                                "linear-boot2.bin",
                                8,
                                user_base + geometry.user,
                                geometry.boot1,
                            ),
                            ("user-first.bin", 8, user_base + geometry.user, user_base),
                            ("user-mbr.bin", 8, user_base + geometry.user, 0x1400000),
                            (
                                "user-last.bin",
                                8,
                                user_base + geometry.user,
                                user_base + geometry.user - 0x100000,
                            ),
                        ];
                        for (name, partition, capacity, address) in ranges {
                            let path = std::path::Path::new(&args[2]).join(name);
                            let mut sink = FileSink(
                                std::fs::OpenOptions::new()
                                    .write(true)
                                    .create_new(true)
                                    .open(path)
                                    .map_err(|e| e.to_string())?,
                            );
                            pollster::block_on(da::read_region(
                                &mut port, partition, capacity, address, 0x100000, &mut sink,
                            ))?;
                            sink.0.sync_all().map_err(|e| e.to_string())?;
                        }
                    }
                    if !raw
                        && !compressed
                        && !flash
                        && !restore
                        && !fetch
                        && !diagnose
                        && !backup_resume
                    {
                        pollster::block_on(da::reboot(&mut port))?;
                    }
                }
                if let Some((bytes, path)) = &completed_backup {
                    println!(
                        "{}",
                        json!({"event":"result","device":info,"report":report,"rebooted":reboot_after_success,"bytes":bytes,"backup_file":path,"format":"raw-emmc-gzip","elapsed_ms":started.elapsed().as_millis()})
                    );
                } else {
                    println!(
                        "{}",
                        json!({"event":"result","device":info,"report":report,"rebooted":reboot_after_success,"partition":partition_result,"elapsed_ms":started.elapsed().as_millis()})
                    );
                }
                return Ok(());
            }
            if started.elapsed() >= Duration::from_secs(seconds) {
                return Err("No preloader found before the wait expired. Start again, then connect a powered-off Y2.".into());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    })();
    if let Err(message) = outcome {
        println!("{}", json!({"event":"error","message":message}));
        std::process::exit(1);
    }
}

#[cfg(target_arch = "wasm32")]
fn main() {}
