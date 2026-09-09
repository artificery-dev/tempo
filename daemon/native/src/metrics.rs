//! Battery and backlight sampling into SQLite - the bring-up `y2-stats`
//! daemon, kept schema-compatible.
//!
//! Every `interval` a row goes into `samples`; rows older than the
//! retention are pruned hourly so the file stays bounded (a week by
//! default). Everything comes from sysfs, so a sample is a few file reads
//! and one INSERT. The latest sample is also kept in memory for the control
//! socket's `battery` op.

use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, params};
use serde::Serialize;
use serde_json::{Map, Value};

/// The Y2's battery (mt6323 PMIC) and panel backlight, by name.
pub const BATTERY_SYSFS: &str = "/sys/class/power_supply/mt6323-battery";
pub const BACKLIGHT_SYSFS: &str = "/sys/class/backlight/mt6323-backlight";

/// Where the readings come from. Missing devices read as nulls.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Sysfs {
    pub battery: Option<PathBuf>,
    pub backlight: Option<PathBuf>,
}

impl Sysfs {
    /// The Y2's devices when present, else the first battery-class power
    /// supply and the first backlight (so a development host reads its
    /// own), overridable with `TEMPOD_BATTERY_SYSFS` /
    /// `TEMPOD_BACKLIGHT_SYSFS`.
    pub fn discover(env: impl Fn(&str) -> Option<String>) -> Sysfs {
        let battery = env("TEMPOD_BATTERY_SYSFS")
            .map(PathBuf::from)
            .or_else(|| existing(BATTERY_SYSFS))
            .or_else(|| {
                first_entry("/sys/class/power_supply", |d| {
                    read_str(&d.join("type")).as_deref() == Some("Battery")
                })
            });
        let backlight = env("TEMPOD_BACKLIGHT_SYSFS")
            .map(PathBuf::from)
            .or_else(|| existing(BACKLIGHT_SYSFS))
            .or_else(|| first_entry("/sys/class/backlight", |_| true));
        Sysfs { battery, backlight }
    }
}

fn existing(path: &str) -> Option<PathBuf> {
    let p = PathBuf::from(path);
    p.exists().then_some(p)
}

/// The alphabetically first entry of `dir` satisfying `keep`.
fn first_entry(dir: &str, keep: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .collect();
    entries.sort();
    entries.into_iter().find(|p| keep(p))
}

/// Read a sysfs attribute, trimmed; None if missing or unreadable.
fn read_str(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
}

fn read_i64(path: &Path) -> Option<i64> {
    read_str(path).and_then(|s| s.parse().ok())
}

pub fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// One reading. Serializes to the fields of the `battery` reply.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Sample {
    /// Unix seconds.
    pub ts: i64,
    /// Battery percent, 0..100.
    pub capacity: Option<i64>,
    /// Battery voltage, microvolts.
    pub voltage_uv: Option<i64>,
    /// Charging right now (status == "Charging").
    pub charging: Option<bool>,
    /// The raw power_supply status string.
    pub status: Option<String>,
    /// Raw backlight brightness.
    pub backlight: Option<i64>,
    /// Brightness, 0..100.
    pub backlight_pct: Option<i64>,
}

impl Sample {
    /// Read everything now.
    pub fn read(sysfs: &Sysfs) -> Sample {
        Sample::read_at(sysfs, now_unix())
    }

    /// Read everything, stamped `ts`.
    pub fn read_at(sysfs: &Sysfs, ts: i64) -> Sample {
        let mut s = Sample {
            ts,
            ..Default::default()
        };
        if let Some(b) = &sysfs.battery {
            s.capacity = read_i64(&b.join("capacity"));
            s.voltage_uv = read_i64(&b.join("voltage_now"));
            s.status = read_str(&b.join("status"));
            s.charging = s.status.as_deref().map(|st| st == "Charging");
        }
        if let Some(bl) = &sysfs.backlight {
            s.backlight = read_i64(&bl.join("brightness"));
            let max = read_i64(&bl.join("max_brightness")).filter(|&m| m > 0);
            s.backlight_pct = match (s.backlight, max) {
                (Some(b), Some(m)) => Some((b * 100 / m).clamp(0, 100)),
                _ => None,
            };
        }
        s
    }

    /// The reply fields for `battery`.
    pub fn fields(&self) -> Map<String, Value> {
        match serde_json::to_value(self) {
            Ok(Value::Object(map)) => map,
            _ => Map::new(),
        }
    }
}

/// The SQLite store. Same schema as y2-stats, so old databases open as-is.
pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Store> {
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
            let _ = std::fs::create_dir_all(dir);
        }
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS samples (
                ts            INTEGER NOT NULL,  -- unix seconds
                capacity      INTEGER,           -- battery percent 0..100
                voltage_uv    INTEGER,           -- battery voltage, microvolts
                charging      INTEGER,           -- 1 if charging, else 0
                status        TEXT,              -- raw power_supply status
                backlight     INTEGER,           -- raw brightness
                backlight_pct INTEGER            -- brightness 0..100
             );
             CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);",
        )?;
        Ok(Store { conn })
    }

    pub fn insert(&self, s: &Sample) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO samples
                (ts, capacity, voltage_uv, charging, status, backlight, backlight_pct)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                s.ts,
                s.capacity,
                s.voltage_uv,
                s.charging.map(i64::from),
                s.status,
                s.backlight,
                s.backlight_pct
            ],
        )?;
        Ok(())
    }

    /// Delete rows older than `retention_days`; 0 keeps everything.
    /// Returns how many went.
    pub fn prune(&self, retention_days: u64) -> rusqlite::Result<usize> {
        if retention_days == 0 {
            return Ok(0);
        }
        let cutoff = now_unix() - (retention_days as i64) * 86_400;
        self.conn
            .execute("DELETE FROM samples WHERE ts < ?1", [cutoff])
    }

    /// The most recent row.
    #[cfg(test)]
    pub fn latest(&self) -> rusqlite::Result<Option<Sample>> {
        use rusqlite::OptionalExtension;
        self.conn
            .query_row(
                "SELECT ts, capacity, voltage_uv, charging, status, backlight, backlight_pct
                 FROM samples ORDER BY ts DESC, rowid DESC LIMIT 1",
                [],
                |row| {
                    Ok(Sample {
                        ts: row.get(0)?,
                        capacity: row.get(1)?,
                        voltage_uv: row.get(2)?,
                        charging: row.get::<_, Option<i64>>(3)?.map(|c| c != 0),
                        status: row.get(4)?,
                        backlight: row.get(5)?,
                        backlight_pct: row.get(6)?,
                    })
                },
            )
            .optional()
    }

    #[cfg(test)]
    pub fn count(&self) -> rusqlite::Result<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM samples", [], |r| r.get(0))
    }
}

#[derive(Debug, Clone)]
pub struct Sampler {
    pub db: PathBuf,
    pub interval: Duration,
    pub retention_days: u64,
}

/// The sampler thread. Never returns; if the database cannot be opened it
/// keeps trying every interval rather than taking the control socket down
/// with it.
pub fn run(cfg: Sampler, sysfs: Sysfs, latest: Arc<Mutex<Option<Sample>>>) {
    let store = loop {
        match Store::open(&cfg.db) {
            Ok(s) => break s,
            Err(e) => {
                log!(
                    "metrics",
                    "cannot open {}: {e}; retrying in {:?}",
                    cfg.db.display(),
                    cfg.interval
                );
                thread::sleep(cfg.interval);
            }
        }
    };
    log!(
        "metrics",
        "logging to {} every {}s, {}",
        cfg.db.display(),
        cfg.interval.as_secs(),
        if cfg.retention_days == 0 {
            "kept forever".to_string()
        } else {
            format!("{}d retention", cfg.retention_days)
        }
    );

    // Prune once at start, then roughly hourly.
    prune(&store, cfg.retention_days);
    let mut since_prune = Duration::ZERO;

    loop {
        let sample = Sample::read(&sysfs);
        if let Ok(mut slot) = latest.lock() {
            *slot = Some(sample.clone());
        }
        if let Err(e) = store.insert(&sample) {
            log!("metrics", "insert failed: {e}");
        }
        since_prune += cfg.interval;
        if since_prune >= Duration::from_secs(3_600) {
            prune(&store, cfg.retention_days);
            since_prune = Duration::ZERO;
        }
        thread::sleep(cfg.interval);
    }
}

fn prune(store: &Store, retention_days: u64) {
    match store.prune(retention_days) {
        Ok(0) => {}
        Ok(n) => log!(
            "metrics",
            "pruned {n} sample(s) older than {retention_days}d"
        ),
        Err(e) => log!("metrics", "prune failed: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    /// A throwaway directory, removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> TempDir {
            let dir = std::env::temp_dir().join(format!("tempod-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            TempDir(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn fake_sysfs(dir: &Path, status: &str) -> Sysfs {
        let batt = dir.join("battery");
        let bl = dir.join("backlight");
        fs::create_dir_all(&batt).unwrap();
        fs::create_dir_all(&bl).unwrap();
        fs::write(batt.join("capacity"), "57\n").unwrap();
        fs::write(batt.join("voltage_now"), "3912000\n").unwrap();
        fs::write(batt.join("status"), format!("{status}\n")).unwrap();
        fs::write(bl.join("brightness"), "128\n").unwrap();
        fs::write(bl.join("max_brightness"), "255\n").unwrap();
        Sysfs {
            battery: Some(batt),
            backlight: Some(bl),
        }
    }

    #[test]
    fn reads_a_sample_from_sysfs() {
        let tmp = TempDir::new("sysfs");
        let sysfs = fake_sysfs(&tmp.0, "Charging");
        let s = Sample::read_at(&sysfs, 1_700_000_000);
        assert_eq!(
            s,
            Sample {
                ts: 1_700_000_000,
                capacity: Some(57),
                voltage_uv: Some(3_912_000),
                charging: Some(true),
                status: Some("Charging".into()),
                backlight: Some(128),
                backlight_pct: Some(50),
            }
        );
        fs::write(
            sysfs.battery.as_ref().unwrap().join("status"),
            "Discharging",
        )
        .unwrap();
        assert_eq!(Sample::read_at(&sysfs, 1).charging, Some(false));
    }

    #[test]
    fn missing_devices_read_as_nulls() {
        let s = Sample::read_at(&Sysfs::default(), 5);
        assert_eq!(
            s,
            Sample {
                ts: 5,
                ..Default::default()
            }
        );
        let tmp = TempDir::new("partial");
        let sysfs = Sysfs {
            battery: Some(tmp.0.join("nope")),
            backlight: None,
        };
        assert_eq!(
            Sample::read_at(&sysfs, 6),
            Sample {
                ts: 6,
                ..Default::default()
            }
        );
    }

    #[test]
    fn backlight_percent_is_clamped_and_needs_a_max() {
        let tmp = TempDir::new("bl");
        let sysfs = fake_sysfs(&tmp.0, "Full");
        let bl = sysfs.backlight.clone().unwrap();
        fs::write(bl.join("brightness"), "300").unwrap();
        assert_eq!(Sample::read_at(&sysfs, 1).backlight_pct, Some(100));
        fs::write(bl.join("max_brightness"), "0").unwrap();
        assert_eq!(Sample::read_at(&sysfs, 1).backlight_pct, None);
        assert_eq!(Sample::read_at(&sysfs, 1).backlight, Some(300));
    }

    #[test]
    fn discovery_honors_the_environment() {
        let env = |k: &str| match k {
            "TEMPOD_BATTERY_SYSFS" => Some("/x/batt".to_string()),
            "TEMPOD_BACKLIGHT_SYSFS" => Some("/x/bl".to_string()),
            _ => None,
        };
        let sysfs = Sysfs::discover(env);
        assert_eq!(sysfs.battery, Some(PathBuf::from("/x/batt")));
        assert_eq!(sysfs.backlight, Some(PathBuf::from("/x/bl")));
        // Without overrides it never panics, whatever the host has.
        let _ = Sysfs::discover(|_| None);
    }

    #[test]
    fn reply_fields() {
        let s = Sample {
            ts: 9,
            capacity: Some(50),
            ..Default::default()
        };
        let f = s.fields();
        assert_eq!(f["ts"], serde_json::json!(9));
        assert_eq!(f["capacity"], serde_json::json!(50));
        assert_eq!(f["charging"], Value::Null);
        assert_eq!(f.len(), 7);
    }

    #[test]
    fn store_roundtrip_and_prune() {
        let tmp = TempDir::new("db");
        let store = Store::open(&tmp.0.join("nested").join("tempod.db")).unwrap();
        assert_eq!(store.latest().unwrap(), None);

        let old = Sample {
            ts: now_unix() - 3 * 86_400,
            capacity: Some(10),
            ..Default::default()
        };
        let new = Sample {
            ts: now_unix(),
            capacity: Some(80),
            voltage_uv: Some(4_100_000),
            charging: Some(true),
            status: Some("Charging".into()),
            backlight: Some(10),
            backlight_pct: Some(4),
        };
        store.insert(&old).unwrap();
        store.insert(&new).unwrap();
        assert_eq!(store.count().unwrap(), 2);
        assert_eq!(store.latest().unwrap(), Some(new.clone()));

        assert_eq!(store.prune(0).unwrap(), 0, "0 keeps everything");
        assert_eq!(store.prune(7).unwrap(), 0, "3 days old is within a week");
        assert_eq!(store.prune(1).unwrap(), 1);
        assert_eq!(store.count().unwrap(), 1);
        assert_eq!(store.latest().unwrap(), Some(new));
    }
}
