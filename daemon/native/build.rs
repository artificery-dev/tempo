//! Bake the daemon's default paths in from config.yaml.
//!
//! daemon/scripts/build reads `daemon.socket`, `daemon.state_dir`,
//! `daemon.sample_interval` and `user.uid` through scripts/config and passes
//! them in as `TEMPOD_DEFAULT_*` environment variables; this turns them into
//! `env!()` constants (src/settings.rs). A plain `cargo build`/`cargo test`
//! outside that script - the host unit tests - gets the fallbacks below, which
//! mirror config.yaml so both paths agree. The binary that ships always comes
//! from the script.

use std::env;

const DEFAULTS: [(&str, &str); 4] = [
    ("TEMPOD_DEFAULT_SOCKET", "/run/tempod/tempod.sock"),
    ("TEMPOD_DEFAULT_STATE_DIR", "/var/lib/tempod"),
    ("TEMPOD_DEFAULT_INTERVAL", "30"),
    ("TEMPOD_DEFAULT_USER_UID", "1000"),
];

fn main() {
    for (key, fallback) in DEFAULTS {
        println!("cargo:rerun-if-env-changed={key}");
        let value = match env::var(key) {
            Ok(v) if !v.trim().is_empty() => v.trim().to_string(),
            _ => fallback.to_string(),
        };
        validate(key, &value);
        println!("cargo:rustc-env={key}={value}");
    }
}

fn validate(key: &str, value: &str) {
    let ok = match key {
        "TEMPOD_DEFAULT_INTERVAL" => value.parse::<u64>().map(|n| n >= 1).unwrap_or(false),
        "TEMPOD_DEFAULT_USER_UID" => value.parse::<u32>().is_ok(),
        _ => value.starts_with('/') && !value.contains('\n'),
    };
    if !ok {
        panic!("{key}={value:?} is not valid (check daemon.* in config.yaml)");
    }
}
