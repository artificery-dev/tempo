//! First-run choices made in the Toolbox, checked the way the player checks
//! them before anything is written, with the password hashed here so that
//! only its hash ever reaches a file.
use std::path::Path;

use serde_json::{Map, Value};

use crate::Result;

/// Reads a setup document as the Toolbox writes it and returns the bytes
/// the player will find at `/first-run-config.json`.
pub fn load(path: &Path) -> Result<Vec<u8>> {
    let text = std::fs::read(path).map_err(|e| format!("Device setup {}: {e}", path.display()))?;
    let document: Value =
        serde_json::from_slice(&text).map_err(|e| format!("Device setup is not JSON: {e}"))?;
    let Value::Object(fields) = document else {
        return Err("Device setup must be a JSON object".into());
    };
    let prepared = prepare(fields)?;
    serde_json::to_vec(&prepared).map_err(|e| e.to_string())
}

/// Checks every field and replaces a password with its hash. Fields the
/// player does not know are refused rather than passed on.
pub fn prepare(mut fields: Map<String, Value>) -> Result<Map<String, Value>> {
    fields.retain(|_, value| !value.is_null());
    if let Some(password) = fields.remove("password") {
        let password = password
            .as_str()
            .filter(|p| !p.is_empty())
            .ok_or("Password must be a non-empty string")?;
        if fields.contains_key("password_hash") {
            return Err("Give a password or its hash, not both".into());
        }
        let hash = sha_crypt::sha512_simple(password, &sha_crypt::Sha512Params::default())
            .map_err(|e| format!("Password hashing failed: {e:?}"))?;
        fields.insert("password_hash".into(), Value::String(hash));
    }
    if fields.is_empty() {
        return Err("Device setup has nothing to apply".into());
    }
    for (key, value) in &fields {
        let text = || {
            value
                .as_str()
                .ok_or_else(|| format!("Device setup {key} must be a string"))
        };
        let ok = match key.as_str() {
            "username" => {
                let name = text()?;
                if name == "root" {
                    return Err("The account cannot be root".into());
                }
                username(name)
            }
            "password_hash" => crypt_hash(text()?),
            "hostname" => hostname(text()?),
            "pretty_hostname" => {
                let line = text()?;
                !line.is_empty() && !line.contains('\n')
            }
            "timezone" => timezone(text()?),
            "locale" => locale(text()?),
            "ssh_keys" => value
                .as_array()
                .is_some_and(|keys| keys.iter().all(|k| k.as_str().is_some_and(ssh_key))),
            _ => return Err(format!("Device setup has an unknown field {key}")),
        };
        if !ok {
            return Err(match key.as_str() {
                "username" => "Account name: lowercase letters, digits, - and _; up to 32, not starting with a digit or -".into(),
                "password_hash" => "Password hash is not a crypt(3) hash".into(),
                "hostname" => "Device name: letters, digits and -; up to 63, not starting with -".into(),
                "pretty_hostname" => "Pretty host name must be one line".into(),
                "timezone" => "Time zone must be a zone name such as Europe/Berlin".into(),
                "locale" => "Language must be a locale such as en_US.UTF-8".into(),
                "ssh_keys" => "SSH keys must be public keys, one per entry".into(),
                _ => unreachable!(),
            });
        }
    }
    Ok(fields)
}

/// `^[a-z_][a-z0-9_-]{0,31}$`, as the player checks it.
fn username(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c == '_')
        && name.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// `^[A-Za-z0-9][A-Za-z0-9-]{0,62}$`.
fn hostname(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && name.len() <= 63
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// A `crypt(3)` hash as `chpasswd -e` takes it.
fn crypt_hash(text: &str) -> bool {
    let mut parts = text.splitn(3, '$');
    parts.next() == Some("")
        && matches!(
            parts.next(),
            Some("y" | "gy" | "7" | "2a" | "2b" | "2x" | "2y" | "6" | "5" | "1")
        )
        && parts.next().is_some_and(|rest| !rest.is_empty())
}

/// A zoneinfo path: the player checks that the zone exists.
fn timezone(zone: &str) -> bool {
    !zone.is_empty()
        && !zone.starts_with('/')
        && zone
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
        && zone
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '+' | '-' | '/'))
}

/// `^[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]+)?$`.
fn locale(text: &str) -> bool {
    let (language, rest) = text.split_at(text.find(['_', '.']).unwrap_or(text.len()));
    if !(2..=3).contains(&language.len()) || !language.bytes().all(|b| b.is_ascii_lowercase()) {
        return false;
    }
    let rest = match rest.strip_prefix('_') {
        Some(territory) => {
            let (territory, rest) =
                territory.split_at(territory.find('.').unwrap_or(territory.len()));
            if territory.len() != 2 || !territory.bytes().all(|b| b.is_ascii_uppercase()) {
                return false;
            }
            rest
        }
        None => rest,
    };
    match rest.strip_prefix('.') {
        Some(encoding) => {
            !encoding.is_empty()
                && encoding
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        }
        None => rest.is_empty(),
    }
}

/// `^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)\S+ \S+`.
fn ssh_key(key: &str) -> bool {
    let mut words = key.split(' ');
    words.next().is_some_and(|kind| {
        ["ssh-", "ecdsa-", "sk-ssh-", "sk-ecdsa-"]
            .iter()
            .any(|prefix| kind.starts_with(prefix) && kind.len() > prefix.len())
    }) && words
        .next()
        .is_some_and(|data| !data.is_empty() && !data.chars().any(char::is_whitespace))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn fields(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(fields) => fields,
            _ => unreachable!(),
        }
    }

    #[test]
    fn a_password_leaves_as_its_hash_and_the_rest_passes_through() {
        let prepared = prepare(fields(json!({
            "username": "alice", "password": "correct horse", "hostname": "alices-y2",
            "timezone": "Europe/Berlin", "locale": "de_DE.UTF-8",
            "ssh_keys": ["ssh-ed25519 AAAAC3Nza alice@laptop"], "pretty_hostname": null,
        })))
        .unwrap();
        assert!(prepared.get("password").is_none());
        let hash = prepared["password_hash"].as_str().unwrap();
        assert!(hash.starts_with("$6$"));
        assert!(sha_crypt::sha512_check("correct horse", hash).is_ok());
        assert_eq!(prepared["username"], "alice");
        assert_eq!(prepared.len(), 6);
        let bytes = serde_json::to_vec(&prepared).unwrap();
        assert!(!bytes.contains(&0) && !bytes.windows(13).any(|w| w == b"correct horse"));
    }

    #[test]
    fn what_the_player_would_refuse_is_refused_here() {
        for (document, reason) in [
            (json!({}), "nothing to apply"),
            (json!({"password": ""}), "non-empty"),
            (json!({"username": "root"}), "root"),
            (json!({"username": "Alice"}), "Account name"),
            (json!({"username": "1st"}), "Account name"),
            (json!({"hostname": "-y2"}), "Device name"),
            (json!({"hostname": "a b"}), "Device name"),
            (json!({"timezone": "/etc/passwd"}), "Time zone"),
            (json!({"timezone": "Europe/../shadow"}), "Time zone"),
            (json!({"locale": "english"}), "Language"),
            (json!({"locale": "en_us"}), "Language"),
            (json!({"ssh_keys": "ssh-ed25519 AAAA"}), "SSH keys"),
            (json!({"ssh_keys": ["rsa AAAA"]}), "SSH keys"),
            (json!({"password_hash": "hunter2"}), "crypt"),
            (
                json!({"password": "x", "password_hash": "$6$a$b"}),
                "not both",
            ),
            (json!({"colour": "red"}), "unknown field"),
            (json!({"username": 7}), "must be a string"),
        ] {
            let error = prepare(fields(document.clone())).unwrap_err();
            assert!(error.contains(reason), "{document}: {error}");
        }
        for document in [
            json!({"timezone": "UTC"}),
            json!({"timezone": "America/Argentina/Buenos_Aires"}),
            json!({"timezone": "Etc/GMT+3"}),
            json!({"locale": "en"}),
            json!({"locale": "en_GB"}),
            json!({"locale": "ast_ES.UTF-8"}),
            json!({"username": "_svc-1"}),
            json!({"ssh_keys": ["sk-ssh-ed25519@openssh.com AAAA", "ecdsa-sha2-nistp256 AAAA me"]}),
            json!({"password_hash": "$y$j9T$salt$hash"}),
        ] {
            prepare(fields(document.clone())).unwrap_or_else(|e| panic!("{document}: {e}"));
        }
    }

    #[test]
    fn a_document_on_disk_is_read_and_must_be_an_object() {
        let dir = std::env::temp_dir().join(format!("tempo-setup-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("setup.json");
        std::fs::write(&path, b"[1]").unwrap();
        assert!(load(&path).unwrap_err().contains("object"));
        std::fs::write(&path, b"{\"hostname\":\"y2\"}").unwrap();
        assert_eq!(load(&path).unwrap(), b"{\"hostname\":\"y2\"}");
        assert!(
            load(&dir.join("missing.json"))
                .unwrap_err()
                .contains("missing.json")
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
