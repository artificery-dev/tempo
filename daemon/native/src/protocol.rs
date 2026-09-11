//! The wire format of the control socket.
//!
//! One connection carries one request: a JSON object on a single line,
//! terminated by `\n`, and gets exactly one JSON object back on a single
//! line, after which tempod closes the connection. The request names its
//! operation in `"op"`; the reply always has `"ok"`, and `"error"` when it
//! is false.

use std::time::Duration;

use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::{haptic, radio, screen, sound, volume};

/// Longest request line accepted, in bytes. Requests are a handful of bytes;
/// anything near this is not a client we know.
pub const MAX_REQUEST_LEN: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    /// `{"op":"ping"}` -> `{"ok":true,"version":...}`
    Ping,
    Power(crate::power::Action),
    FormatSd,
    EjectSd,
    /// Set Debian’s IANA time zone through systemd-timedated.
    Timezone(String),
    /// `{"op":"battery"}` -> `{"ok":true, ...latest sample...}`
    Battery,
    /// `{"op":"drm-handoff"}` with the DRM fd as SCM_RIGHTS -> `{"ok":true}`
    DrmHandoff,
    /// `{"op":"screen"[,"on":bool][,"brightness":N][,"fade_ms":N]}` ->
    /// `{"ok":true,"on":bool,"brightness":N,"max":N}`. Nothing but `op` is
    /// a query.
    Screen(screen::Request),
    /// `{"op":"volume"[,"level":N][,"step":N]}` ->
    /// `{"ok":true,"level":N,"muted":bool}`. Nothing but `op` is a query;
    /// `level` is absolute (0..=100), `step` relative.
    Volume(volume::Request),
    /// `{"op":"output"}` ->
    /// `{"ok":true,"output":"speaker"|"headphones","jack":bool}`
    Output(Option<String>),
    /// `{"op":"haptic"[,"pattern":"click"|"tick"|"thump"][,"ms":N][,"strength":
    /// N]}` -> `{"ok":true,"available":true,"played_ms":N}`. Nothing but
    /// `op` is a query.
    Haptic(haptic::Request),
    /// `{"op":"sound","name":"tick"|"click"|"thump"[,"speaker_only":bool]}` ->
    /// `{"ok":true}`
    Sound(sound::Name, bool),
    /// `{"op":"fm"[,"on":bool][,"frequency_khz":N][,"seek":-1|1]}` ->
    /// the receiver's current frequency, signal, stereo state, and any
    /// decoded RDS fields. Nothing but `op` is a query.
    Fm(radio::Request),
    /// `{"op":"first-run"}` asks where first run stands;
    /// `{"op":"first-run","pending":{...}}` queues what the setup chose.
    FirstRun(Option<Map<String, Value>>),
    /// `{"op":"clock"[,"set":"YYYY-MM-DD HH:MM:SS"]}` -> whether the clock is
    /// synchronised, and the time; `set` puts the clock right by hand.
    Clock(Option<String>),
    /// Anything else, kept for the log line.
    Unknown(String),
}

#[derive(Deserialize)]
struct Request {
    op: String,
    confirm: Option<bool>,
    zone: Option<String>,
    // The screen op's fields; ignored by every other op.
    on: Option<bool>,
    brightness: Option<i64>,
    fade_ms: Option<u64>,
    // The volume op's fields.
    level: Option<i64>,
    step: Option<i64>,
    // The haptic op's fields.
    pattern: Option<String>,
    ms: Option<u32>,
    strength: Option<u32>,
    // The sound op's field.
    name: Option<String>,
    #[serde(default)]
    speaker_only: bool,
    target: Option<String>,
    // The FM op's field (`on` is shared with screen).
    frequency_khz: Option<i64>,
    seek: Option<i64>,
    // The first-run op's field.
    pending: Option<Map<String, Value>>,
    // The clock op's field.
    set: Option<String>,
}

/// Parse one request line (without its terminating newline). The error is
/// the message to send back.
pub fn parse_request(line: &[u8]) -> Result<Op, String> {
    let text = std::str::from_utf8(line).map_err(|_| "request is not UTF-8".to_string())?;
    if text.trim().is_empty() {
        return Err("empty request".to_string());
    }
    let req: Request = serde_json::from_str(text).map_err(|e| format!("malformed request: {e}"))?;
    Ok(match req.op.as_str() {
        "ping" => Op::Ping,
        "reboot" => Op::Power(crate::power::Action::Restart),
        "poweroff" => Op::Power(crate::power::Action::Shutdown),
        "format-sd" if req.confirm == Some(true) => Op::FormatSd,
        "format-sd" => return Err("Formatting requires explicit confirmation".into()),
        "timezone" => Op::Timezone(req.zone.ok_or("timezone needs a zone")?),
        "eject-sd" => Op::EjectSd,
        "battery" => Op::Battery,
        "drm-handoff" => Op::DrmHandoff,
        "screen" => Op::Screen(screen::Request {
            on: req.on,
            brightness: req.brightness,
            fade: req.fade_ms.map(Duration::from_millis),
        }),
        "output" => Op::Output(req.target),
        "sound" => {
            let name = req.name.as_deref().unwrap_or("");
            Op::Sound(
                sound::Name::parse(name).ok_or_else(|| format!("unknown sound {name:?}"))?,
                req.speaker_only,
            )
        }
        "fm" => Op::Fm(radio::Request {
            on: req.on,
            frequency_khz: req.frequency_khz,
            seek: req.seek,
        }),
        "haptic" => Op::Haptic(haptic::Request {
            pattern: req.pattern,
            ms: req.ms,
            strength: req.strength,
        }),
        "volume" => Op::Volume(volume::Request {
            level: req.level,
            step: req.step,
        }),
        "first-run" => Op::FirstRun(req.pending),
        "clock" => Op::Clock(req.set),
        other => Op::Unknown(other.to_string()),
    })
}

/// A success reply carrying `fields`, as one newline-terminated line.
pub fn ok_line(fields: Map<String, Value>) -> String {
    let mut obj = fields;
    obj.insert("ok".into(), Value::Bool(true));
    line(Value::Object(obj))
}

/// `{"ok":true}` and nothing else.
pub fn ok_empty() -> String {
    ok_line(Map::new())
}

/// A failure reply, as one newline-terminated line.
pub fn error_line(message: impl AsRef<str>) -> String {
    line(json!({ "ok": false, "error": message.as_ref() }))
}

fn line(value: Value) -> String {
    // serde_json escapes control characters inside strings, so the only
    // newline in the output is the terminator.
    let mut s = value.to_string();
    s.push('\n');
    s
}

#[cfg(test)]
mod tests {
    #[test]
    fn sd_maintenance_requests() {
        assert_eq!(
            super::parse_request(br#"{"op":"eject-sd"}"#).unwrap(),
            super::Op::EjectSd
        );
        assert_eq!(
            super::parse_request(br#"{"op":"format-sd","confirm":true}"#).unwrap(),
            super::Op::FormatSd
        );
        assert!(super::parse_request(br#"{"op":"format-sd"}"#).is_err());
        assert!(super::parse_request(br#"{"op":"format-sd","confirm":false}"#).is_err());
    }

    use super::*;

    #[test]
    fn known_ops() {
        assert_eq!(parse_request(br#"{"op":"ping"}"#), Ok(Op::Ping));
        assert_eq!(parse_request(br#"{"op":"battery"}"#), Ok(Op::Battery));
        assert_eq!(
            parse_request(br#"{"op":"drm-handoff"}"#),
            Ok(Op::DrmHandoff)
        );
        // Extra fields are tolerated; only op matters to these.
        assert_eq!(parse_request(br#"{"op":"ping","id":7}"#), Ok(Op::Ping));
        assert_eq!(parse_request(b"  {\"op\":\"ping\"}\r"), Ok(Op::Ping));
    }

    #[test]
    fn sound_routing_is_optional_for_older_clients() {
        assert_eq!(
            parse_request(br#"{"op":"sound","name":"click"}"#),
            Ok(Op::Sound(sound::Name::Click, false))
        );
        assert_eq!(
            parse_request(br#"{"op":"sound","name":"tick","speaker_only":true}"#),
            Ok(Op::Sound(sound::Name::Tick, true))
        );
        assert!(parse_request(br#"{"op":"sound","name":"click","speaker_only":"yes"}"#).is_err());
    }

    #[test]
    fn timezone_requests() {
        assert_eq!(
            parse_request(br#"{"op":"timezone","zone":"America/New_York"}"#),
            Ok(Op::Timezone("America/New_York".into()))
        );
        assert!(parse_request(br#"{"op":"timezone"}"#).is_err());
        assert!(parse_request(br#"{"op":"timezone","zone":42}"#).is_err());
    }

    #[test]
    fn screen_requests() {
        assert_eq!(
            parse_request(br#"{"op":"screen"}"#),
            Ok(Op::Screen(screen::Request::default()))
        );
        assert_eq!(
            parse_request(br#"{"op":"screen","on":false,"fade_ms":250}"#),
            Ok(Op::Screen(screen::Request {
                on: Some(false),
                brightness: None,
                fade: Some(Duration::from_millis(250)),
            }))
        );
        assert_eq!(
            parse_request(br#"{"op":"screen","brightness":60}"#),
            Ok(Op::Screen(screen::Request {
                on: None,
                brightness: Some(60),
                fade: None,
            }))
        );
        // The wrong type for a field is malformed, not ignored.
        assert!(
            parse_request(br#"{"op":"screen","on":"yes"}"#)
                .unwrap_err()
                .starts_with("malformed request")
        );
    }

    #[test]
    fn fm_requests() {
        assert_eq!(
            parse_request(br#"{"op":"fm"}"#),
            Ok(Op::Fm(radio::Request::default()))
        );
        assert_eq!(
            parse_request(br#"{"op":"fm","on":true,"frequency_khz":95500}"#),
            Ok(Op::Fm(radio::Request {
                on: Some(true),
                frequency_khz: Some(95_500),
                seek: None,
            }))
        );
        assert_eq!(
            parse_request(br#"{"op":"fm","seek":-1}"#),
            Ok(Op::Fm(radio::Request {
                on: None,
                frequency_khz: None,
                seek: Some(-1),
            }))
        );
    }

    #[test]
    fn unknown_op_is_reported_not_rejected() {
        assert_eq!(
            parse_request(br#"{"op":"unsupported"}"#),
            Ok(Op::Unknown("unsupported".into()))
        );
    }

    #[test]
    fn malformed_requests() {
        assert_eq!(parse_request(b""), Err("empty request".into()));
        assert_eq!(parse_request(b"   "), Err("empty request".into()));
        assert!(
            parse_request(b"{")
                .unwrap_err()
                .starts_with("malformed request")
        );
        assert!(
            parse_request(b"[1]")
                .unwrap_err()
                .starts_with("malformed request")
        );
        assert!(
            parse_request(b"{}")
                .unwrap_err()
                .starts_with("malformed request")
        );
        assert!(
            parse_request(br#"{"op":5}"#)
                .unwrap_err()
                .starts_with("malformed request")
        );
        assert_eq!(
            parse_request(&[0xff, 0xfe]),
            Err("request is not UTF-8".into())
        );
    }

    #[test]
    fn replies_are_single_json_lines() {
        let ok = ok_empty();
        assert_eq!(ok, "{\"ok\":true}\n");

        let mut fields = Map::new();
        fields.insert("version".into(), json!("1.2.3"));
        let ok = ok_line(fields);
        let v: Value = serde_json::from_str(ok.trim_end()).unwrap();
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["version"], json!("1.2.3"));
        assert_eq!(ok.matches('\n').count(), 1);
        assert!(ok.ends_with('\n'));

        let err = error_line("line one\nline two");
        let v: Value = serde_json::from_str(err.trim_end()).unwrap();
        assert_eq!(v["ok"], json!(false));
        assert_eq!(v["error"], json!("line one\nline two"));
        assert_eq!(
            err.matches('\n').count(),
            1,
            "newlines inside the message stay escaped"
        );
    }

    #[test]
    fn ok_cannot_be_overridden_by_fields() {
        let mut fields = Map::new();
        fields.insert("ok".into(), json!(false));
        let v: Value = serde_json::from_str(ok_line(fields).trim_end()).unwrap();
        assert_eq!(v["ok"], json!(true));
    }
}
