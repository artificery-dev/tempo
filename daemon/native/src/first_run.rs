//! First run: what the device's setup asks for is written down here, as
//! root, for `tempo-system first-run-apply` to carry out at the next boot,
//! before the account it may rename has any process running.
//!
//! `{"op":"first-run"}` ->
//! `{"ok":true,"done":bool,"applied":{...},"error":str?}` `{"op":"first-run","
//! pending":{...}}` -> `{"ok":true}` while first run is open; refused once it
//! is done, so nothing in the account's group can queue a rename or a password
//! after that.
//!
//! The file's shape is checked here at the door - known fields, the right
//! types, a hash rather than a password - and checked again in full by the
//! tool that applies it.

use std::{
    fs,
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

use serde_json::{Map, Value, json};

pub const STATE: &str = "/var/lib/tempo/first-run";

const FIELDS: &[&str] = &[
    "username",
    "password_hash",
    "hostname",
    "pretty_hostname",
    "timezone",
    "locale",
    "ssh_keys",
];

pub struct FirstRun {
    state: PathBuf,
}

impl Default for FirstRun {
    fn default() -> Self {
        Self::at(Path::new(STATE))
    }
}

impl FirstRun {
    pub fn at(state: &Path) -> Self {
        FirstRun {
            state: state.to_path_buf(),
        }
    }

    fn done(&self) -> bool {
        self.state.join("done").exists()
    }

    /// Where first run stands: whether it is done, what has been applied so
    /// far (never a secret), and the last failure to apply, if any.
    pub fn status(&self) -> Map<String, Value> {
        let mut fields = Map::new();
        fields.insert("done".into(), json!(self.done()));
        let applied = fs::read_to_string(self.state.join("applied.json"))
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .unwrap_or_else(|| json!({}));
        fields.insert("applied".into(), applied);
        if let Ok(error) = fs::read_to_string(self.state.join("error")) {
            fields.insert("error".into(), json!(error.trim()));
        }
        fields
    }

    /// Records what the setup asks for, to be applied at the next boot. A
    /// `password` is hashed here and stored as `password_hash`: the file
    /// only ever holds what `chpasswd -e` takes.
    pub fn queue(&self, pending: &Map<String, Value>) -> Result<(), String> {
        if self.done() {
            return Err("first run is already done".into());
        }
        let mut pending = pending.clone();
        if let Some(password) = pending.remove("password") {
            let password = password
                .as_str()
                .filter(|p| !p.is_empty())
                .ok_or("password is not a non-empty string")?;
            let hash = sha_crypt::sha512_simple(password, &sha_crypt::Sha512Params::default())
                .map_err(|e| format!("password hashing failed: {e:?}"))?;
            pending.insert("password_hash".into(), Value::String(hash));
        }
        let pending = &pending;
        validate(pending)?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.state)
            .map_err(|e| format!("first-run state: {e}"))?;
        let path = self.state.join("pending.json");
        let temporary = self.state.join("pending.json.tmp");
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|e| format!("first-run pending: {e}"))?;
        let merged = match fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        {
            Some(Value::Object(mut earlier)) => {
                earlier.extend(pending.clone());
                earlier
            }
            _ => pending.clone(),
        };
        writeln!(file, "{}", Value::Object(merged)).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::rename(&temporary, &path).map_err(|e| e.to_string())
    }
}

fn validate(pending: &Map<String, Value>) -> Result<(), String> {
    if pending.is_empty() {
        return Err("pending is empty".into());
    }
    for (key, value) in pending {
        if !FIELDS.contains(&key.as_str()) {
            return Err(format!("unknown first-run field {key:?}"));
        }
        let ok = match key.as_str() {
            "ssh_keys" => value.as_array().is_some_and(|keys| {
                keys.iter().all(|k| {
                    k.as_str().is_some_and(|s| {
                        s.starts_with("ssh-") || s.starts_with("ecdsa-") || s.starts_with("sk-")
                    })
                })
            }),
            "password_hash" => value.as_str().is_some_and(is_crypt_hash),
            _ => value
                .as_str()
                .is_some_and(|s| !s.is_empty() && !s.contains('\n')),
        };
        if !ok {
            return Err(format!("first-run field {key:?} is not acceptable"));
        }
    }
    Ok(())
}

/// A `crypt(3)` hash as `chpasswd -e` takes it. A password itself is
/// refused: it must be hashed before it reaches a file.
fn is_crypt_hash(text: &str) -> bool {
    let mut parts = text.splitn(3, '$');
    parts.next() == Some("")
        && matches!(
            parts.next(),
            Some("y" | "gy" | "7" | "2a" | "2b" | "2x" | "2y" | "6" | "5" | "1")
        )
        && parts.next().is_some_and(|rest| !rest.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A state directory of this test's own, removed when it goes.
    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn fixture() -> (Scratch, FirstRun) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static COUNT: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "tempo-first-run-{}-{}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        let state = dir.join("first-run");
        (Scratch(dir), FirstRun::at(&state))
    }

    fn object(text: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(text)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    #[test]
    fn status_starts_open_and_empty() {
        let (_dir, first_run) = fixture();
        let status = first_run.status();
        assert_eq!(status["done"], json!(false));
        assert_eq!(status["applied"], json!({}));
        assert!(!status.contains_key("error"));
    }

    #[test]
    fn pending_is_written_for_root_alone_and_merged() {
        let (_dir, first_run) = fixture();
        first_run
            .queue(&object(r#"{"hostname":"player"}"#))
            .unwrap();
        first_run
            .queue(&object(
                r#"{"username":"alice","password_hash":"$6$salt$hash"}"#,
            ))
            .unwrap();
        let path = first_run.state.join("pending.json");
        let written: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            written,
            json!({"hostname":"player","username":"alice","password_hash":"$6$salt$hash"})
        );
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn a_password_is_refused_unless_hashed() {
        let (_dir, first_run) = fixture();
        assert!(
            first_run
                .queue(&object(r#"{"password_hash":"hunter2"}"#))
                .is_err()
        );
        assert!(
            first_run
                .queue(&object(r#"{"password_hash":"$6$"}"#))
                .is_err()
        );
        assert!(
            first_run
                .queue(&object(r#"{"password_hash":"$y$j9T$abc"}"#))
                .is_ok()
        );
    }

    #[test]
    fn a_plain_password_is_hashed_before_it_touches_the_file() {
        let (_dir, first_run) = fixture();
        assert!(first_run.queue(&object(r#"{"password":""}"#)).is_err());
        first_run
            .queue(&object(r#"{"password":"correct horse"}"#))
            .unwrap();
        let text = fs::read_to_string(first_run.state.join("pending.json")).unwrap();
        assert!(!text.contains("correct horse"), "{text}");
        let written: Value = serde_json::from_str(&text).unwrap();
        assert!(written.get("password").is_none());
        let hash = written["password_hash"].as_str().unwrap();
        assert!(hash.starts_with("$6$"), "{hash}");
        assert!(sha_crypt::sha512_check("correct horse", hash).is_ok());
    }

    #[test]
    fn unknown_or_malformed_fields_are_refused() {
        let (_dir, first_run) = fixture();
        assert!(first_run.queue(&object(r#"{}"#)).is_err());
        assert!(first_run.queue(&object(r#"{"colour":"blue"}"#)).is_err());
        assert!(first_run.queue(&object(r#"{"hostname":42}"#)).is_err());
        assert!(
            first_run
                .queue(&object(r#"{"hostname":"two\nlines"}"#))
                .is_err()
        );
        assert!(
            first_run
                .queue(&object(r#"{"ssh_keys":["not a key"]}"#))
                .is_err()
        );
        assert!(
            first_run
                .queue(&object(r#"{"ssh_keys":["ssh-ed25519 AAAA me"]}"#))
                .is_ok()
        );
    }

    #[test]
    fn nothing_is_queued_once_first_run_is_done() {
        let (_dir, first_run) = fixture();
        fs::create_dir_all(&first_run.state).unwrap();
        fs::write(first_run.state.join("done"), "").unwrap();
        fs::write(
            first_run.state.join("applied.json"),
            r#"{"username":"alice"}"#,
        )
        .unwrap();
        fs::write(first_run.state.join("error"), "the last time: nothing\n").unwrap();
        let status = first_run.status();
        assert_eq!(status["done"], json!(true));
        assert_eq!(status["applied"], json!({"username":"alice"}));
        assert_eq!(status["error"], json!("the last time: nothing"));
        assert!(
            first_run
                .queue(&object(r#"{"hostname":"player"}"#))
                .is_err()
        );
    }
}
