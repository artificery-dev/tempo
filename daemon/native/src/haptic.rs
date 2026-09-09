//! The `haptic` op: the vibration motor, through the kernel's
//! force-feedback interface.
//!
//! The Y2's motor hangs off the PMIC's VIBR rail; mainline's
//! regulator-haptic turns that into an input device with one rumble
//! effect, and ff-memless plays it for a length at a strength. tempod
//! uploads one effect at start and re-arms it per request: a click is a
//! few tens of milliseconds at full strength, a tick a shorter, softer
//! one, and the frontend asks for either by name or by numbers.

use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    sync::Mutex,
};

use serde_json::{Map, Value, json};

/// What regulator-haptic calls its input device.
const HAPTIC_DEVICE_NAME: &str = "regulator-haptic";
const EV_FF: u16 = 0x15;
const FF_RUMBLE: u16 = 0x50;
/// The most any one request may rumble for.
const MAX_MS: u32 = 2000;

/// What the frontend asked for: a named pattern, or a length and a
/// strength of its own. An empty request is a query.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Request {
    pub pattern: Option<String>,
    pub ms: Option<u32>,
    /// 0..=100.
    pub strength: Option<u32>,
}

/// The `haptic` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub available: bool,
    pub played_ms: u32,
}

impl Status {
    pub fn fields(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("available".into(), json!(self.available));
        m.insert("played_ms".into(), json!(self.played_ms));
        m
    }
}

/// A named pattern: (length, strength).
fn pattern(name: &str) -> Option<(u32, u32)> {
    // An eccentric-mass motor needs time to spin up: nothing under ~20 ms
    // is felt, and the rail's floor leaves little room in the strength.
    match name {
        "click" => Some((45, 100)),
        "tick" => Some((25, 100)),
        "thump" => Some((100, 100)),
        _ => None,
    }
}

/// `struct ff_effect` for `FF_RUMBLE`, as `<linux/input.h>` lays it out on
/// a 32-bit ARM: the union is sized by its largest member (periodic).
#[repr(C)]
struct FfReplay {
    length: u16,
    delay: u16,
}

#[repr(C)]
struct FfTrigger {
    button: u16,
    interval: u16,
}

#[repr(C)]
struct FfRumbleEffect {
    strong_magnitude: u16,
    weak_magnitude: u16,
}

#[repr(C)]
struct FfEffect {
    type_: u16,
    id: i16,
    direction: u16,
    trigger: FfTrigger,
    replay: FfReplay,
    // The union: ff_periodic_effect is the largest member (it carries a
    // pointer, so the size differs by word size; see the test below).
    // Byte-aligned here, so the header pads to the union's alignment on
    // a 64-bit host exactly as the kernel's does - by the explicit pad.
    _pad: [u8; FF_EFFECT_HEADER_PAD],
    u: [u8; FF_EFFECT_UNION_LEN],
}

#[cfg(target_pointer_width = "32")]
const FF_EFFECT_HEADER_PAD: usize = 2;
#[cfg(target_pointer_width = "64")]
const FF_EFFECT_HEADER_PAD: usize = 2;
#[cfg(target_pointer_width = "32")]
const FF_EFFECT_UNION_LEN: usize = 28;
#[cfg(target_pointer_width = "64")]
const FF_EFFECT_UNION_LEN: usize = 32;

#[repr(C)]
struct InputEvent {
    time: libc::timeval,
    type_: u16,
    code: u16,
    value: i32,
}

/// The motor as a resource: the device, and the one effect uploaded to
/// it.
pub struct Haptic {
    inner: Mutex<Option<Armed>>,
    input_class: PathBuf,
}

struct Armed {
    file: File,
    effect_id: i16,
}

impl Haptic {
    pub fn new(input_class: PathBuf) -> Haptic {
        Haptic {
            inner: Mutex::new(None),
            input_class,
        }
    }

    /// Carry out `req`.
    pub fn apply(&self, req: &Request) -> Result<Status, String> {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            *guard = Some(Armed::open(&self.input_class)?);
        }
        let (ms, strength) = match (&req.pattern, req.ms, req.strength) {
            (Some(name), _, _) => {
                pattern(name).ok_or_else(|| format!("unknown pattern {name:?}"))?
            }
            (None, Some(ms), strength) => (ms, strength.unwrap_or(100)),
            (None, None, _) => {
                return Ok(Status {
                    available: true,
                    played_ms: 0,
                });
            }
        };
        let ms = ms.min(MAX_MS);
        let strength = strength.min(100);
        let armed = guard.as_mut().expect("armed above");
        match armed.play(ms, strength) {
            Ok(()) => Ok(Status {
                available: true,
                played_ms: ms,
            }),
            Err(e) => {
                // The device may have gone (a reflash mid-session); arm again
                // next time.
                *guard = None;
                Err(e)
            }
        }
    }
}

impl Armed {
    fn open(input_class: &Path) -> Result<Armed, String> {
        let node = haptic_device(input_class)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&node)
            .map_err(|e| format!("cannot open {}: {e}", node.display()))?;
        let mut effect = FfEffect {
            type_: FF_RUMBLE,
            id: -1,
            direction: 0,
            trigger: FfTrigger {
                button: 0,
                interval: 0,
            },
            replay: FfReplay {
                length: 0,
                delay: 0,
            },
            _pad: [0; FF_EFFECT_HEADER_PAD],
            u: [0; FF_EFFECT_UNION_LEN],
        };
        upload(&file, &mut effect)?;
        Ok(Armed {
            file,
            effect_id: effect.id,
        })
    }

    fn play(&mut self, ms: u32, strength: u32) -> Result<(), String> {
        let magnitude = (0xffff * strength / 100) as u16;
        let mut effect = FfEffect {
            type_: FF_RUMBLE,
            id: self.effect_id,
            direction: 0,
            trigger: FfTrigger {
                button: 0,
                interval: 0,
            },
            replay: FfReplay {
                length: ms as u16,
                delay: 0,
            },
            _pad: [0; FF_EFFECT_HEADER_PAD],
            u: [0; FF_EFFECT_UNION_LEN],
        };
        let rumble = FfRumbleEffect {
            strong_magnitude: magnitude,
            weak_magnitude: magnitude,
        };
        // SAFETY: FfRumbleEffect is 4 plain bytes, copied into the union.
        let bytes = unsafe {
            std::slice::from_raw_parts(
                (&rumble as *const FfRumbleEffect) as *const u8,
                size_of::<FfRumbleEffect>(),
            )
        };
        effect.u[..bytes.len()].copy_from_slice(bytes);
        upload(&self.file, &mut effect)?;
        self.effect_id = effect.id;
        let play = InputEvent {
            time: libc::timeval {
                tv_sec: 0,
                tv_usec: 0,
            },
            type_: EV_FF,
            code: self.effect_id as u16,
            value: 1,
        };
        // SAFETY: InputEvent is plain data of the size the kernel reads.
        let bytes = unsafe {
            std::slice::from_raw_parts(
                (&play as *const InputEvent) as *const u8,
                size_of::<InputEvent>(),
            )
        };
        self.file
            .write_all(bytes)
            .map_err(|e| format!("cannot play the effect: {e}"))
    }
}

/// `EVIOCSFF`: upload (or update) an effect; the kernel fills in `id`.
fn upload(file: &File, effect: &mut FfEffect) -> Result<(), String> {
    // EVIOCSFF = _IOW('E', 0x80, struct ff_effect)
    let request = (1u64 << 30 | (size_of::<FfEffect>() as u64) << 16 | (b'E' as u64) << 8 | 0x80)
        as libc::c_ulong;
    // SAFETY: the struct matches the kernel's layout for this target.
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), request, effect as *mut FfEffect) };
    if rc < 0 {
        return Err(format!("EVIOCSFF: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

fn haptic_device(input_class: &Path) -> Result<PathBuf, String> {
    let entries = fs::read_dir(input_class)
        .map_err(|e| format!("cannot read {}: {e}", input_class.display()))?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("event") {
            continue;
        }
        let label = fs::read_to_string(entry.path().join("device/name")).unwrap_or_default();
        if label.trim() == HAPTIC_DEVICE_NAME {
            return Ok(PathBuf::from("/dev/input").join(&*name));
        }
    }
    Err("no haptic device".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effect_matches_the_kernel_size() {
        // sizeof(struct ff_effect): 44 on 32-bit, 48 on 64-bit
        // (ff_periodic_effect carries a pointer).
        #[cfg(target_pointer_width = "32")]
        assert_eq!(size_of::<FfEffect>(), 44);
        #[cfg(target_pointer_width = "64")]
        assert_eq!(size_of::<FfEffect>(), 48);
        assert_eq!(size_of::<InputEvent>(), size_of::<libc::timeval>() + 8);
    }

    #[test]
    fn patterns() {
        assert_eq!(pattern("click"), Some((45, 100)));
        assert_eq!(pattern("tick"), Some((25, 100)));
        assert!(pattern("bounce").is_none());
    }

    #[test]
    fn no_device_is_an_error() {
        let dir = std::env::temp_dir().join(format!("tempod-haptic-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let h = Haptic::new(dir.clone());
        let req = Request {
            pattern: Some("click".into()),
            ..Default::default()
        };
        assert!(h.apply(&req).is_err());
        fs::remove_dir_all(&dir).unwrap();
    }
}
