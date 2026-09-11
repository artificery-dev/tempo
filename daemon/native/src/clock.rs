//! The system clock, through systemd-timedated: whether it is synchronised
//! over the network, and setting it by hand when it is not. The RTC follows
//! either way, as timedatectl keeps it.
//!
//! `{"op":"clock"}` -> `{"ok":true,"synchronized":bool,"ntp":bool,"now":"..."}`
//! `{"op":"clock","set":"2026-09-11 10:00:00"}` -> the same, after setting.
//! Setting turns network time off for the moment it takes and back on, so a
//! network that arrives later still corrects the hand-set clock.

use std::{
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};

use serde_json::{Map, Value, json};

static CHANGE: Mutex<()> = Mutex::new(());

pub fn status() -> Result<Map<String, Value>, String> {
    read(run)
}

pub fn set(when: &str) -> Result<Map<String, Value>, String> {
    let _guard = CHANGE.lock().map_err(|e| e.to_string())?;
    apply(when, run)
}

/// `YYYY-MM-DD HH:MM:SS`, the form timedatectl documents.
fn valid(when: &str) -> bool {
    let b = when.as_bytes();
    b.len() == 19
        && b.iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b' ',
            13 | 16 => *c == b':',
            _ => c.is_ascii_digit(),
        })
        && when[..4]
            .parse::<u32>()
            .is_ok_and(|y| (2020..=2100).contains(&y))
}

fn apply(
    when: &str,
    mut command: impl FnMut(&[&str]) -> Result<String, String>,
) -> Result<Map<String, Value>, String> {
    if !valid(when) {
        return Err("clock wants YYYY-MM-DD HH:MM:SS".into());
    }
    command(&["--no-ask-password", "set-ntp", "false"])?;
    let set = command(&["--no-ask-password", "set-time", when]);
    let ntp = command(&["--no-ask-password", "set-ntp", "true"]);
    set?;
    ntp?;
    read(command)
}

fn read(
    mut command: impl FnMut(&[&str]) -> Result<String, String>,
) -> Result<Map<String, Value>, String> {
    let shown = command(&[
        "show",
        "--property=NTPSynchronized",
        "--property=NTP",
        "--property=TimeUSec",
    ])?;
    let mut synchronized = false;
    let mut ntp = false;
    let mut now = String::new();
    for line in shown.lines() {
        match line.split_once('=') {
            Some(("NTPSynchronized", v)) => synchronized = v.trim() == "yes",
            Some(("NTP", v)) => ntp = v.trim() == "yes",
            Some(("TimeUSec", v)) => now = v.trim().to_string(),
            _ => {}
        }
    }
    let mut fields = Map::new();
    fields.insert("synchronized".into(), json!(synchronized));
    fields.insert("ntp".into(), json!(ntp));
    fields.insert("now".into(), json!(now));
    Ok(fields)
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
    fn the_form_is_exact() {
        assert!(valid("2026-09-11 10:00:00"));
        assert!(!valid("2026-9-11 10:00:00"));
        assert!(!valid("2026-09-11T10:00:00"));
        assert!(!valid("1999-09-11 10:00:00"));
        assert!(!valid("2026-09-11 10:00:00; reboot"));
    }

    #[test]
    fn setting_turns_ntp_off_and_back_on_around_the_time() {
        let mut calls = Vec::new();
        let result = apply("2026-09-11 10:00:00", |args| {
            calls.push(args.join(" "));
            Ok(if args[0] == "show" {
                "NTPSynchronized=no\nNTP=yes\nTimeUSec=Fri 2026-09-11 10:00:00 UTC\n".into()
            } else {
                String::new()
            })
        })
        .unwrap();
        assert_eq!(
            calls,
            [
                "--no-ask-password set-ntp false",
                "--no-ask-password set-time 2026-09-11 10:00:00",
                "--no-ask-password set-ntp true",
                "show --property=NTPSynchronized --property=NTP --property=TimeUSec",
            ]
        );
        assert_eq!(result["synchronized"], json!(false));
        assert_eq!(result["ntp"], json!(true));
        assert_eq!(result["now"], json!("Fri 2026-09-11 10:00:00 UTC"));
    }

    #[test]
    fn ntp_comes_back_on_even_when_setting_fails() {
        let mut calls = Vec::new();
        let result = apply("2026-09-11 10:00:00", |args| {
            calls.push(args.join(" "));
            if args.contains(&"set-time") {
                Err("no".into())
            } else {
                Ok(String::new())
            }
        });
        assert!(result.is_err());
        assert!(calls.iter().any(|c| c == "--no-ask-password set-ntp true"));
    }

    #[test]
    fn status_reads_what_timedated_says() {
        let fields = read(|_| Ok("NTPSynchronized=yes\nNTP=yes\nTimeUSec=now\n".into())).unwrap();
        assert_eq!(fields["synchronized"], json!(true));
    }
}
