//! Debian's system zone, changed through systemd-timedated rather than the
//! daemon process's TZ environment. The RTC remains on its existing UTC basis.

use std::{
    fs,
    io::Read,
    path::Path,
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};

static CHANGE: Mutex<()> = Mutex::new(());

fn validate(zone: &str, root: &Path) -> Result<(), String> {
    if zone.is_empty()
        || zone.len() > 255
        || !zone.split('/').all(|part| {
            !part.is_empty()
                && part != "."
                && part != ".."
                && part
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"_+-".contains(&c))
        })
        || zone.starts_with('-')
    {
        return Err("invalid time zone name".into());
    }
    let path = root
        .join(zone)
        .canonicalize()
        .map_err(|e| format!("unknown time zone: {e}"))?;
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    if !path.starts_with(root) {
        return Err("time zone is outside the zone database".into());
    }
    let mut magic = [0; 4];
    fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .map_err(|e| format!("cannot read time zone: {e}"))?;
    if &magic != b"TZif" {
        return Err("not a time zone file".into());
    }
    Ok(())
}

pub fn set(zone: &str) -> Result<(), String> {
    let _guard = CHANGE.lock().map_err(|e| e.to_string())?;
    apply(zone, Path::new("/usr/share/zoneinfo"), run)
}

fn apply(
    zone: &str,
    root: &Path,
    mut command: impl FnMut(&[&str]) -> Result<String, String>,
) -> Result<(), String> {
    validate(zone, root)?;
    command(&["--no-ask-password", "set-timezone", zone])?;
    let actual = command(&["show", "--property=Timezone", "--value"])?;
    if actual.trim() != zone {
        return Err(format!("time zone readback differs: {}", actual.trim()));
    }
    Ok(())
}

fn run(args: &[&str]) -> Result<String, String> {
    let mut child = Command::new("/usr/bin/timedatectl")
        .args(args)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("timedatectl: {e}"))?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if start.elapsed() < Duration::from_secs(8) => {
                thread::sleep(Duration::from_millis(20))
            }
            result => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(match result {
                    Err(e) => format!("timedatectl: {e}"),
                    _ => "timedatectl timed out".into(),
                });
            }
        }
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "timedatectl: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_installed_zones_and_rejects_paths_and_non_zones() {
        let root = Path::new("/usr/share/zoneinfo");
        for zone in ["UTC", "America/New_York", "Asia/Kathmandu"] {
            assert!(validate(zone, root).is_ok(), "{zone}");
        }
        for zone in [
            "",
            "../etc/passwd",
            "/etc/localtime",
            "America/../UTC",
            "--help",
            "zone.tab",
            "Unknown/Place",
        ] {
            assert!(validate(zone, root).is_err(), "{zone}");
        }
    }

    #[test]
    fn sets_then_verifies_and_propagates_failures() {
        let root = Path::new("/usr/share/zoneinfo");
        let mut calls = Vec::new();
        apply("UTC", root, |args| {
            calls.push(args.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            Ok("UTC\n".into())
        })
        .unwrap();
        assert_eq!(
            calls,
            vec![
                vec!["--no-ask-password", "set-timezone", "UTC"],
                vec!["show", "--property=Timezone", "--value"]
            ]
        );
        assert!(apply("UTC", root, |_| Err("permission denied".into())).is_err());
        assert!(apply("UTC", root, |_| Ok("Europe/London".into())).is_err());
        assert!(apply("../UTC", root, |_| panic!("invalid zone ran a command")).is_err());
    }
}
