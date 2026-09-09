//! The `volume` op: the sound server's default sink, through `wpctl`.
//!
//! PipeWire runs in the player user's own systemd instance, so its socket
//! lives under that user's runtime directory; tempod, root, reaches it by
//! pointing `XDG_RUNTIME_DIR` there for the `wpctl` it spawns. The level is
//! 0..=100 as WirePlumber shows it (its cubic curve, so 50 is a comfortable
//! middle rather than half power), and a request is one get, or one set
//! followed by a get, so the reply is always what the mixer now says.

use std::{path::PathBuf, process::Command, sync::Mutex};

use serde_json::{Map, Value, json};

use crate::settings;

/// What WirePlumber calls the sink the player hears.
const SINK: &str = "@DEFAULT_AUDIO_SINK@";
/// Never past full: WirePlumber would happily go to 150 %.
const MAX_LEVEL: i64 = 100;

/// What the frontend asked for. Everything optional: an empty request is a
/// query; `level` is absolute, `step` relative, and `level` wins when both
/// are given.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Request {
    pub level: Option<i64>,
    pub step: Option<i64>,
}

/// The `volume` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    /// 0..=100.
    pub level: i64,
    pub muted: bool,
    pub device: Option<String>,
    pub hardware: bool,
}

impl Status {
    pub fn fields(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("level".into(), json!(self.level));
        m.insert("muted".into(), json!(self.muted));
        m.insert("device".into(), json!(self.device));
        m.insert("hardware".into(), json!(self.hardware));
        m
    }
}

/// The mixer as a resource: one request at a time, so two quick steps
/// land in order.
pub struct Volume {
    lock: Mutex<()>,
    runtime_dir: PathBuf,
}

impl Volume {
    pub fn new(runtime_dir: PathBuf) -> Volume {
        Volume {
            lock: Mutex::new(()),
            runtime_dir,
        }
    }

    /// Where the player user's PipeWire socket is: `TEMPOD_RUNTIME_DIR`
    /// if set, else `/run/user/<uid>` for the uid config.yaml names.
    pub fn runtime_dir() -> PathBuf {
        match std::env::var("TEMPOD_RUNTIME_DIR") {
            Ok(dir) if !dir.trim().is_empty() => PathBuf::from(dir.trim()),
            _ => PathBuf::from(format!("/run/user/{}", settings::DEFAULT_USER_UID)),
        }
    }

    /// Carry out `req` and say where the sink ended up.
    pub fn apply(&self, req: &Request) -> Result<Status, String> {
        let _serialized = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let target = match (req.level, req.step) {
            (Some(level), _) => Some(level),
            (None, Some(step)) => Some(self.read()?.level + step),
            (None, None) => None,
        };
        if let Some(level) = target {
            let level = level.clamp(0, MAX_LEVEL);
            self.wpctl(&["set-volume", SINK, &format!("{level}%")])?;
            log!("volume", "level {level}");
        }
        self.read()
    }

    fn read(&self) -> Result<Status, String> {
        let out = self.wpctl(&["get-volume", SINK])?;
        parse_get_volume(&out)
    }

    fn wpctl(&self, args: &[&str]) -> Result<String, String> {
        let output = Command::new("wpctl")
            .args(args)
            .env("XDG_RUNTIME_DIR", &self.runtime_dir)
            .output()
            .map_err(|e| format!("cannot run wpctl: {e}"))?;
        if !output.status.success() {
            let err = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "wpctl {} failed ({}): {}",
                args.join(" "),
                output.status,
                err.trim()
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }
}

/// `wpctl get-volume` prints `Volume: 0.50` or `Volume: 0.50 [MUTED]`.
fn parse_get_volume(out: &str) -> Result<Status, String> {
    let line = out
        .lines()
        .find(|l| l.trim_start().starts_with("Volume:"))
        .ok_or_else(|| format!("unexpected wpctl output: {}", out.trim()))?;
    let mut words = line.split_whitespace().skip(1);
    let number = words
        .next()
        .ok_or_else(|| format!("no level in {line:?}"))?
        .parse::<f64>()
        .map_err(|_| format!("bad level in {line:?}"))?;
    let muted = words.any(|w| w == "[MUTED]");
    Ok(Status {
        level: (number * 100.0).round().clamp(0.0, MAX_LEVEL as f64) as i64,
        muted,
        device: None,
        hardware: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_level() {
        let s = parse_get_volume("Volume: 0.50\n").unwrap();
        assert_eq!(
            s,
            Status {
                level: 50,
                muted: false,
                device: None,
                hardware: false
            }
        );
    }

    #[test]
    fn parses_muted() {
        let s = parse_get_volume("Volume: 0.35 [MUTED]\n").unwrap();
        assert_eq!(
            s,
            Status {
                level: 35,
                muted: true,
                device: None,
                hardware: false
            }
        );
    }

    #[test]
    fn caps_past_full() {
        let s = parse_get_volume("Volume: 1.50\n").unwrap();
        assert_eq!(s.level, 100);
    }

    #[test]
    fn rejects_noise() {
        assert!(parse_get_volume("Could not connect\n").is_err());
        assert!(parse_get_volume("Volume: loud\n").is_err());
    }

    #[test]
    fn fields_carry_both() {
        let f = Status {
            level: 7,
            muted: true,
            device: None,
            hardware: false,
        }
        .fields();
        assert_eq!(f["level"], json!(7));
        assert_eq!(f["muted"], json!(true));
    }
}
