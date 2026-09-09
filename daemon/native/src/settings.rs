//! Where things live and how often to look: compile-time defaults from
//! config.yaml (via build.rs), overridable at runtime.
//!
//! Precedence, highest first: command-line flag, `TEMPOD_*` environment
//! variable, systemd's `STATE_DIRECTORY` (for the database), compile-time
//! default.

use std::{path::PathBuf, time::Duration};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Baked in by build.rs from `daemon.socket`.
pub const DEFAULT_SOCKET: &str = env!("TEMPOD_DEFAULT_SOCKET");
/// Baked in by build.rs from `daemon.state_dir`.
pub const DEFAULT_STATE_DIR: &str = env!("TEMPOD_DEFAULT_STATE_DIR");
/// Baked in by build.rs from `daemon.sample_interval` (seconds, as text).
pub const DEFAULT_INTERVAL: &str = env!("TEMPOD_DEFAULT_INTERVAL");
/// Baked in by build.rs from `user.uid`: whose runtime directory holds the
/// sound server's socket.
pub const DEFAULT_USER_UID: &str = env!("TEMPOD_DEFAULT_USER_UID");
/// The metrics database, inside the state directory.
pub const DB_FILE: &str = "tempod.db";
/// Days of samples to keep; 0 keeps everything.
pub const DEFAULT_RETENTION_DAYS: u64 = 7;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    /// Control socket path. Ignored when systemd passes the socket in.
    pub socket: PathBuf,
    /// Metrics database path.
    pub db: PathBuf,
    /// Time between metric samples.
    pub interval: Duration,
    /// Days of samples to keep; 0 = forever.
    pub retention_days: u64,
    /// Run the sampler thread at all.
    pub sampler: bool,
}

/// What the command line asked for.
#[derive(Debug, PartialEq, Eq)]
pub enum Cli {
    Run(Settings),
    /// Print this and exit successfully (`--help`, `--version`).
    Exit(String),
}

const USAGE: &str = "usage: tempod [--socket PATH] [--db PATH] [--interval SECS] \
                     [--retention DAYS] [--no-sampler]";

pub fn help() -> String {
    format!(
        "tempod {VERSION} - the Tempo device and service daemon

{USAGE}

  --socket PATH     control socket (default {DEFAULT_SOCKET}; env TEMPOD_SOCKET).
                    Ignored when socket-activated by systemd (LISTEN_FDS).
  --db PATH         metrics database (default {DEFAULT_STATE_DIR}/{DB_FILE};
                    env TEMPOD_DB, else $STATE_DIRECTORY/{DB_FILE}).
  --interval SECS   seconds between samples (default {DEFAULT_INTERVAL}; env TEMPOD_INTERVAL).
  --retention DAYS  days of samples to keep, 0 = forever (default {DEFAULT_RETENTION_DAYS};
                    env TEMPOD_RETENTION).
  --no-sampler      serve the control socket only.
  -V, --version     print the version.
  -h, --help        this text.

The defaults are baked in from config.yaml (daemon.*) by daemon/scripts/build."
    )
}

/// Parse the command line against an environment lookup. `env` is a
/// parameter rather than `std::env::var` so the precedence is testable.
pub fn parse<I, E>(args: I, env: E) -> Result<Cli, String>
where
    I: IntoIterator<Item = String>,
    E: Fn(&str) -> Option<String>,
{
    let env = |key: &str| env(key).filter(|v| !v.trim().is_empty());

    let mut socket = env("TEMPOD_SOCKET").unwrap_or_else(|| DEFAULT_SOCKET.to_string());
    let mut db = env("TEMPOD_DB")
        .or_else(|| {
            // systemd's StateDirectory= hands us the path; it may list several,
            // colon separated. The first is ours.
            let dir = env("STATE_DIRECTORY")?;
            let first = dir.split(':').next()?.trim();
            (!first.is_empty()).then(|| format!("{first}/{DB_FILE}"))
        })
        .unwrap_or_else(|| format!("{DEFAULT_STATE_DIR}/{DB_FILE}"));
    let mut interval = env("TEMPOD_INTERVAL").unwrap_or_else(|| DEFAULT_INTERVAL.to_string());
    let mut retention =
        env("TEMPOD_RETENTION").unwrap_or_else(|| DEFAULT_RETENTION_DAYS.to_string());
    let mut sampler = true;

    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        // --flag=value and --flag value are both fine.
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_string(), Some(v.to_string())),
            _ => (arg.clone(), None),
        };
        let mut value = || -> Result<String, String> {
            inline
                .clone()
                .or_else(|| it.next())
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag.as_str() {
            "-h" | "--help" => return Ok(Cli::Exit(help())),
            "-V" | "--version" => return Ok(Cli::Exit(format!("tempod {VERSION}"))),
            "--socket" => socket = value()?,
            "--db" => db = value()?,
            "--interval" => interval = value()?,
            "--retention" => retention = value()?,
            "--no-sampler" => sampler = false,
            other => return Err(format!("unknown option {other}\n{USAGE}")),
        }
    }

    let interval = interval
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|n| *n >= 1)
        .ok_or_else(|| {
            format!("interval must be a whole number of seconds >= 1, not {interval:?}")
        })?;
    let retention_days = retention
        .trim()
        .parse::<u64>()
        .map_err(|_| format!("retention must be a whole number of days, not {retention:?}"))?;

    Ok(Cli::Run(Settings {
        socket: PathBuf::from(socket),
        db: PathBuf::from(db),
        interval: Duration::from_secs(interval),
        retention_days,
        sampler,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn run(list: &[&str], env: impl Fn(&str) -> Option<String>) -> Settings {
        match parse(args(list), env) {
            Ok(Cli::Run(s)) => s,
            other => panic!("expected settings, got {other:?}"),
        }
    }

    #[test]
    fn compile_time_defaults() {
        let s = run(&[], no_env);
        assert_eq!(s.socket, PathBuf::from(DEFAULT_SOCKET));
        assert_eq!(
            s.db,
            PathBuf::from(format!("{DEFAULT_STATE_DIR}/{DB_FILE}"))
        );
        assert_eq!(
            s.interval,
            Duration::from_secs(DEFAULT_INTERVAL.parse().unwrap())
        );
        assert_eq!(s.retention_days, DEFAULT_RETENTION_DAYS);
        assert!(s.sampler);
        // What build.rs was handed (or its fallbacks) must be sane.
        assert!(DEFAULT_SOCKET.starts_with('/'));
        assert!(DEFAULT_STATE_DIR.starts_with('/'));
    }

    #[test]
    fn environment_overrides_defaults() {
        let env = |k: &str| match k {
            "TEMPOD_SOCKET" => Some("/tmp/t.sock".to_string()),
            "TEMPOD_DB" => Some("/tmp/t.db".to_string()),
            "TEMPOD_INTERVAL" => Some("5".to_string()),
            "TEMPOD_RETENTION" => Some("0".to_string()),
            _ => None,
        };
        let s = run(&[], env);
        assert_eq!(s.socket, PathBuf::from("/tmp/t.sock"));
        assert_eq!(s.db, PathBuf::from("/tmp/t.db"));
        assert_eq!(s.interval, Duration::from_secs(5));
        assert_eq!(s.retention_days, 0);
    }

    #[test]
    fn empty_environment_values_are_ignored() {
        let s = run(&[], |k| (k == "TEMPOD_INTERVAL").then(|| "  ".to_string()));
        assert_eq!(
            s.interval,
            Duration::from_secs(DEFAULT_INTERVAL.parse().unwrap())
        );
    }

    #[test]
    fn systemd_state_directory_places_the_database() {
        let env = |k: &str| (k == "STATE_DIRECTORY").then(|| "/var/lib/x:/var/lib/y".to_string());
        assert_eq!(run(&[], env).db, PathBuf::from("/var/lib/x/tempod.db"));
        // TEMPOD_DB still wins over it.
        let env = |k: &str| match k {
            "STATE_DIRECTORY" => Some("/var/lib/x".to_string()),
            "TEMPOD_DB" => Some("/elsewhere.db".to_string()),
            _ => None,
        };
        assert_eq!(run(&[], env).db, PathBuf::from("/elsewhere.db"));
    }

    #[test]
    fn flags_beat_environment() {
        let env = |k: &str| (k == "TEMPOD_INTERVAL").then(|| "5".to_string());
        let s = run(
            &[
                "--interval",
                "9",
                "--socket=/s",
                "--db",
                "/d",
                "--no-sampler",
            ],
            env,
        );
        assert_eq!(s.interval, Duration::from_secs(9));
        assert_eq!(s.socket, PathBuf::from("/s"));
        assert_eq!(s.db, PathBuf::from("/d"));
        assert!(!s.sampler);
    }

    #[test]
    fn bad_input_is_an_error() {
        assert!(parse(args(&["--interval", "0"]), no_env).is_err());
        assert!(parse(args(&["--interval", "soon"]), no_env).is_err());
        assert!(parse(args(&["--retention", "-1"]), no_env).is_err());
        assert!(parse(args(&["--socket"]), no_env).is_err());
        assert!(parse(args(&["--bogus"]), no_env).is_err());
        assert!(parse(args(&["stray"]), no_env).is_err());
    }

    #[test]
    fn help_and_version_exit() {
        assert!(
            matches!(parse(args(&["--help"]), no_env), Ok(Cli::Exit(t)) if t.contains("--socket"))
        );
        assert_eq!(
            parse(args(&["-V"]), no_env),
            Ok(Cli::Exit(format!("tempod {VERSION}")))
        );
    }
}
