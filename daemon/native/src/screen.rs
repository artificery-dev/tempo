//! The panel backlight: off and on - the `screen` op.
//!
//! The frontend runs unprivileged and `/sys/class/backlight/*/brightness`
//! is root's, so putting the screen to sleep is tempod's job. Two sysfs
//! attributes do it: `brightness` (0..=max, the level the driver drives the
//! MT6323's current sinks at) and `bl_power` (`0` = FB_BLANK_UNBLANK, `4` =
//! FB_BLANK_POWERDOWN). While `bl_power` is 4 the backlight core reports a
//! brightness of 0 to the driver whatever `brightness` says, so the level
//! survives the sleep in sysfs and the sampler keeps seeing the user's
//! setting rather than a zero.
//!
//! The animation is the frontend's, not the backlight's. Going to sleep the
//! UI fades its frame to black over the fade and this op waits that long
//! before blanking, so the light goes out under a frame that is already
//! dark; waking, this op unblanks at once and replies, and the UI fades its
//! frame in on a lit panel. A backlight ramp was tried alongside the UI's
//! fade and looked worse than a cut: PMIC writes land tens of milliseconds
//! apart through pwrap, and steps under a smooth fade read as flicker.
//!
//! Requests are serialized, and a request arriving while an earlier one
//! is waiting out its fade cuts that wait short (the `generation` counter),
//! so a wake during a fade-out never blanks a screen the user just asked
//! to see.

use std::{
    path::Path,
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use serde_json::{Map, Value, json};

/// `bl_power` values: FB_BLANK_UNBLANK and FB_BLANK_POWERDOWN.
pub const BL_POWER_ON: i64 = 0;
pub const BL_POWER_OFF: i64 = 4;

/// The fade when the request names none: how long the frontend takes to
/// reach black, which is how long the blank waits.
pub const DEFAULT_FADE: Duration = Duration::from_millis(400);
/// The longest fade a request may ask for; a connection thread sits in it.
pub const MAX_FADE: Duration = Duration::from_secs(5);
/// How often a wait checks whether a newer request has arrived.
const STEP: Duration = Duration::from_millis(10);
/// The dimmest "on" the driver has; a level below it is a request to blank,
/// which is `on: false`'s job, so levels are clamped here.
const FLOOR: i64 = 1;

/// What the frontend asked for. Everything optional: an empty request is a
/// query.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Request {
    /// Turn the backlight on or off. None leaves it as it is.
    pub on: Option<bool>,
    /// A level to set (clamped to 1..=max). With the screen off it is
    /// written under the blank and shows at the next wake.
    pub brightness: Option<i64>,
    /// How long the frontend's fade to black takes, and so how long
    /// `on: false` waits before blanking; None is [`DEFAULT_FADE`].
    pub fade: Option<Duration>,
}

/// The `screen` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    /// `bl_power` is unblanked.
    pub on: bool,
    /// The level in sysfs - the one that shows, or will show at the wake.
    pub brightness: i64,
    pub max: i64,
}

impl Status {
    pub fn fields(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("on".into(), json!(self.on));
        m.insert("brightness".into(), json!(self.brightness));
        m.insert("max".into(), json!(self.max));
        m
    }
}

/// The backlight as a resource: one request at a time, each able to cut a
/// previous request's wait short.
pub struct Screen {
    lock: Mutex<()>,
    /// Bumped by every request before it waits for the lock; a wait compares
    /// it to the value it started under and stops when they differ.
    generation: AtomicU64,
}

impl Default for Screen {
    fn default() -> Screen {
        Screen::new()
    }
}

impl Screen {
    pub fn new() -> Screen {
        Screen {
            lock: Mutex::new(()),
            generation: AtomicU64::new(0),
        }
    }

    /// The backlight as it is now.
    pub fn status(dir: &Path) -> Result<Status, String> {
        let max = read(dir, "max_brightness")?;
        if max <= 0 {
            return Err(format!("max_brightness is {max}"));
        }
        Ok(Status {
            on: read(dir, "bl_power")? == BL_POWER_ON,
            brightness: read(dir, "brightness")?,
            max,
        })
    }

    /// Carry out `req` on the backlight at `dir`, and say how it ended up.
    pub fn apply(&self, dir: &Path, req: &Request) -> Result<Status, String> {
        // Announce ourselves before queueing: whoever holds the lock and is
        // waiting out a fade sees the change and lets go.
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let _serialized = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let fade = req.fade.unwrap_or(DEFAULT_FADE).min(MAX_FADE);
        let mut status = Screen::status(dir)?;

        if let Some(level) = req.brightness {
            let level = level.clamp(FLOOR, status.max);
            if level != status.brightness {
                // On, it shows at once; off, it is what the next wake shows.
                write(dir, "brightness", level)?;
                status.brightness = level;
                log!("screen", "brightness {level}");
            }
        }

        match req.on {
            Some(false) if status.on => {
                // Let the frontend's fade reach black, then cut, so the light
                // goes out under a dark frame. The level stays in sysfs.
                if self.wait(fade, generation) {
                    write(dir, "bl_power", BL_POWER_OFF)?;
                    log!(
                        "screen",
                        "off (after the {} ms fade, level {} kept)",
                        fade.as_millis(),
                        status.brightness
                    );
                } else {
                    log!("screen", "sleep canceled by a newer request before the cut");
                }
            }
            Some(true) if !status.on => {
                // At once: the frontend fades its frame in once we answer.
                write(dir, "bl_power", BL_POWER_ON)?;
                log!("screen", "on (level {})", status.brightness);
            }
            _ => {}
        }

        Screen::status(dir)
    }

    /// Sit out `span` in steps, unless a newer request arrives: true if the
    /// whole span passed.
    fn wait(&self, span: Duration, generation: u64) -> bool {
        let superseded = || self.generation.load(Ordering::SeqCst) != generation;
        let start = Instant::now();
        while start.elapsed() < span {
            if superseded() {
                return false;
            }
            thread::sleep(STEP.min(span - start.elapsed()));
        }
        !superseded()
    }
}

fn read(dir: &Path, attr: &str) -> Result<i64, String> {
    let path = dir.join(attr);
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    text.trim()
        .parse()
        .map_err(|_| format!("{}: not a number: {text:?}", path.display()))
}

fn write(dir: &Path, attr: &str, value: i64) -> Result<(), String> {
    let path = dir.join(attr);
    std::fs::write(&path, format!("{value}\n")).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf, sync::Arc};

    use super::*;

    struct FakeBacklight(PathBuf);

    impl FakeBacklight {
        fn new(tag: &str, brightness: i64, max: i64) -> FakeBacklight {
            let dir =
                std::env::temp_dir().join(format!("tempod-screen-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("brightness"), format!("{brightness}\n")).unwrap();
            fs::write(dir.join("max_brightness"), format!("{max}\n")).unwrap();
            fs::write(dir.join("bl_power"), "0\n").unwrap();
            FakeBacklight(dir)
        }

        fn get(&self, attr: &str) -> i64 {
            read(&self.0, attr).unwrap()
        }
    }

    impl Drop for FakeBacklight {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn quick(on: Option<bool>) -> Request {
        Request {
            on,
            brightness: None,
            fade: Some(Duration::from_millis(30)),
        }
    }

    #[test]
    fn query_reads_the_state() {
        let bl = FakeBacklight::new("query", 124, 124);
        let screen = Screen::new();
        let s = screen.apply(&bl.0, &Request::default()).unwrap();
        assert_eq!(
            s,
            Status {
                on: true,
                brightness: 124,
                max: 124
            }
        );
        let f = s.fields();
        assert_eq!(f["on"], json!(true));
        assert_eq!(f["brightness"], json!(124));
        assert_eq!(f["max"], json!(124));
    }

    #[test]
    fn off_waits_out_the_fade_then_blanks_and_on_is_immediate() {
        let bl = FakeBacklight::new("offon", 90, 124);
        let screen = Screen::new();

        let started = Instant::now();
        let s = screen.apply(&bl.0, &quick(Some(false))).unwrap();
        assert!(
            started.elapsed() >= Duration::from_millis(30),
            "the cut waits for the fade"
        );
        assert!(!s.on);
        assert_eq!(bl.get("bl_power"), BL_POWER_OFF);
        assert_eq!(bl.get("brightness"), 90, "the level survives the sleep");

        // Off again is a no-op, and does not wait.
        let started = Instant::now();
        let s = screen.apply(&bl.0, &quick(Some(false))).unwrap();
        assert!(started.elapsed() < Duration::from_millis(25));
        assert!(!s.on);

        let started = Instant::now();
        let s = screen.apply(&bl.0, &quick(Some(true))).unwrap();
        assert!(
            started.elapsed() < Duration::from_millis(25),
            "on does not wait"
        );
        assert!(s.on);
        assert_eq!(bl.get("bl_power"), BL_POWER_ON);
        assert_eq!(bl.get("brightness"), 90);
    }

    #[test]
    fn brightness_is_set_in_one_write_on_or_off() {
        let bl = FakeBacklight::new("level", 124, 124);
        let screen = Screen::new();
        let s = screen
            .apply(
                &bl.0,
                &Request {
                    brightness: Some(40),
                    ..quick(None)
                },
            )
            .unwrap();
        assert_eq!(s.brightness, 40);
        assert!(s.on);

        screen.apply(&bl.0, &quick(Some(false))).unwrap();
        let s = screen
            .apply(
                &bl.0,
                &Request {
                    brightness: Some(500),
                    ..quick(None)
                },
            )
            .unwrap();
        assert!(!s.on, "setting a level does not wake the screen");
        assert_eq!(s.brightness, 124, "clamped to max");
        assert_eq!(
            bl.get("brightness"),
            124,
            "written under the blank, for the wake"
        );

        // Below the floor is clamped up: blanking is on:false's job.
        let s = screen
            .apply(
                &bl.0,
                &Request {
                    on: Some(true),
                    brightness: Some(0),
                    fade: None,
                },
            )
            .unwrap();
        assert!(s.on);
        assert_eq!(s.brightness, FLOOR);
    }

    #[test]
    fn a_wake_during_the_fade_cancels_the_cut() {
        let bl = FakeBacklight::new("cancel", 124, 124);
        let screen = Arc::new(Screen::new());
        let dir = bl.0.clone();
        let slow = Arc::clone(&screen);
        let sleeping = thread::spawn(move || {
            slow.apply(
                &dir,
                &Request {
                    on: Some(false),
                    brightness: None,
                    fade: Some(Duration::from_secs(2)),
                },
            )
        });
        thread::sleep(Duration::from_millis(80));
        let s = screen.apply(&bl.0, &quick(Some(true))).unwrap();
        let canceled = sleeping.join().unwrap().unwrap();
        assert!(canceled.on, "the sleep was canceled and never blanked");
        assert!(s.on);
        assert_eq!(bl.get("bl_power"), BL_POWER_ON);
    }

    #[test]
    fn a_missing_device_is_an_error_not_a_panic() {
        let screen = Screen::new();
        let err = screen
            .apply(Path::new("/nonexistent/backlight"), &Request::default())
            .unwrap_err();
        assert!(err.contains("max_brightness"));
    }
}
