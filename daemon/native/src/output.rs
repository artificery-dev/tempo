//! The `output` op: where the sound goes.
//!
//! Today that is the headphone jack, read from the switch the DAC's own
//! detect reports through its input device (`SW_HEADPHONE_INSERT` on the
//! "y2-cs43131 Headphone" evdev node): plugged is headphones, unplugged the
//! speaker. WirePlumber does the switching itself, from the same jack; this
//! op only tells the frontend which way it went, so it can say so. A
//! Bluetooth sink, when there is one, joins here as a third answer.

use std::{
    fs,
    os::fd::AsRawFd,
    path::{Path, PathBuf},
};

use serde_json::{Map, Value, json};

/// The input device the CS43131 driver registers for its jack.
const JACK_DEVICE_NAME: &str = "y2-cs43131 Headphone";
/// `SW_HEADPHONE_INSERT` in `<linux/input-event-codes.h>`.
const SW_HEADPHONE_INSERT: u32 = 0x02;
/// `SW_MAX` is 0x0f: one byte would do, and 8 is generous.
const SW_MASK_LEN: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Output {
    Speaker,
    Headphones,
}

impl Output {
    fn as_str(self) -> &'static str {
        match self {
            Output::Speaker => "speaker",
            Output::Headphones => "headphones",
        }
    }
}

/// The `output` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub output: Output,
    /// Whether the jack reports something plugged in.
    pub jack: bool,
}

impl Status {
    pub fn fields(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("output".into(), json!(self.output.as_str()));
        m.insert("jack".into(), json!(self.jack));
        m
    }

    fn from_jack(plugged: bool) -> Status {
        Status {
            output: if plugged {
                Output::Headphones
            } else {
                Output::Speaker
            },
            jack: plugged,
        }
    }
}

/// Where the sound goes right now.
pub fn status(input_class: &Path) -> Result<Status, String> {
    let node = jack_device(input_class)?;
    let plugged = read_switch(&node, SW_HEADPHONE_INSERT)?;
    Ok(Status::from_jack(plugged))
}

/// A monitor belongs to one native runtime, including its child and thread.
/// Killing the child interrupts a blocked JSON read before the thread is
/// joined.
struct Monitor {
    objects: std::sync::Arc<std::sync::Mutex<std::collections::BTreeMap<u64, Value>>>,
    child: std::sync::Arc<std::sync::Mutex<Option<std::process::Child>>>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Monitor {
    fn start(mut command: std::process::Command) -> Self {
        use std::sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering},
        };
        let objects = Arc::new(Mutex::new(std::collections::BTreeMap::new()));
        let child = Arc::new(Mutex::new(None::<std::process::Child>));
        let stop = Arc::new(AtomicBool::new(false));
        let cache = Arc::clone(&objects);
        let process = Arc::clone(&child);
        let stopping = Arc::clone(&stop);
        let thread = std::thread::Builder::new()
            .name("pipewire-monitor".into())
            .spawn(move || {
                while !stopping.load(Ordering::Acquire) {
                    let stdout = {
                        let mut slot = process.lock().unwrap_or_else(|e| e.into_inner());
                        // Serialize spawn with shutdown so a new child cannot
                        // escape it.
                        if stopping.load(Ordering::Acquire) {
                            break;
                        }
                        match command
                            .stdout(std::process::Stdio::piped())
                            .stderr(std::process::Stdio::null())
                            .spawn()
                        {
                            Ok(mut running) => {
                                let stdout = running.stdout.take();
                                *slot = Some(running);
                                stdout
                            }
                            Err(_) => None,
                        }
                    };
                    if let Some(stdout) = stdout {
                        let stream =
                            serde_json::Deserializer::from_reader(stdout).into_iter::<Value>();
                        for update in stream {
                            if stopping.load(Ordering::Acquire) {
                                break;
                            }
                            let Ok(Value::Array(items)) = update else {
                                break;
                            };
                            let mut cache = cache.lock().unwrap_or_else(|e| e.into_inner());
                            for item in items {
                                let Some(id) = item["id"].as_u64() else {
                                    continue;
                                };
                                if item.get("info").is_some_and(Value::is_null) {
                                    cache.remove(&id);
                                } else {
                                    merge(cache.entry(id).or_insert(Value::Null), item);
                                }
                            }
                        }
                    }
                    if let Some(mut running) =
                        process.lock().unwrap_or_else(|e| e.into_inner()).take()
                    {
                        let _ = running.kill();
                        let _ = running.wait();
                    }
                    cache.lock().unwrap_or_else(|e| e.into_inner()).clear();
                    if !stopping.load(Ordering::Acquire) {
                        std::thread::park_timeout(std::time::Duration::from_secs(1));
                    }
                }
            })
            .ok();
        Self {
            objects,
            child,
            stop,
            thread,
        }
    }
}

impl Drop for Monitor {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Release);
        if let Some(child) = self
            .child
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_mut()
        {
            let _ = child.kill();
        }
        if let Some(thread) = self.thread.take() {
            thread.thread().unpark();
            let _ = thread.join();
        }
    }
}

/// PipeWire state is streamed once, rather than spawning a process per poll.
#[derive(Default)]
pub struct Routing {
    monitor: std::sync::OnceLock<Monitor>,
    pinned: std::sync::Mutex<Option<String>>,
}

impl Routing {
    fn snapshot(&self) -> Vec<Value> {
        let monitor = self.monitor.get_or_init(|| {
            let mut command = std::process::Command::new("pw-dump");
            command
                .arg("--monitor")
                .env("XDG_RUNTIME_DIR", crate::volume::Volume::runtime_dir());
            Monitor::start(command)
        });
        monitor
            .objects
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .cloned()
            .collect()
    }

    /// The cached sink properties use linear gain; wpctl/UI use its cube root.
    pub fn volume(&self) -> Option<crate::volume::Status> {
        let objects = self.snapshot();
        let name = objects
            .iter()
            .filter_map(|o| o["metadata"].as_array())
            .flatten()
            .find(|m| m["key"] == "default.audio.sink")?["value"]["name"]
            .as_str()?;
        let sink = objects
            .iter()
            .find(|o| o["info"]["props"]["node.name"] == name)?;
        let props = sink["info"]["params"]["Props"]
            .as_array()?
            .iter()
            .find(|p| p["channelVolumes"].is_array())?;
        let gain = props["channelVolumes"]
            .as_array()?
            .iter()
            .filter_map(Value::as_f64)
            .reduce(f64::max)?;
        let bluetooth = sink["info"]["props"]["device.api"] == "bluez5";
        let card = objects
            .iter()
            .find(|o| o["id"] == sink["info"]["props"]["device.id"]);
        // BlueZ's PipeWire plugin exposes volumeStep only when the transport
        // has active hardware volume. Do not infer support from the name.
        let hardware = bluetooth
            && card
                .and_then(|c| c["info"]["params"]["Route"].as_array())
                .is_some_and(|routes| {
                    routes.iter().any(|r| {
                        r["device"] == sink["info"]["props"]["card.profile.device"]
                            && r["props"]["volumeStep"].as_f64().is_some_and(|v| v > 0.0)
                    })
                });
        let device = bluetooth.then(|| {
            sink["info"]["props"]["node.description"]
                .as_str()
                .unwrap_or("Bluetooth")
                .to_owned()
        });
        Some(crate::volume::Status {
            level: (gain.max(0.0).cbrt() * 100.0).round().clamp(0.0, 100.0) as i64,
            muted: props["mute"].as_bool().unwrap_or(false),
            device,
            hardware,
        })
    }

    pub fn apply(&self, target: Option<&str>) -> Result<Map<String, Value>, String> {
        let objects = self.snapshot();
        let jack_status = status(Path::new("/sys/class/input"))?;
        let jack = jack_status.jack;
        let sinks: Vec<_> = objects
            .iter()
            .filter(|o| o["info"]["props"]["media.class"] == "Audio/Sink")
            .collect();
        let local = sinks.iter().find(|o| {
            o["info"]["props"]["node.name"] == "alsa_output.platform-sound.stereo-fallback"
        });
        let card = objects
            .iter()
            .find(|o| o["info"]["props"]["device.name"] == "alsa_card.platform-sound");
        let default_name = objects
            .iter()
            .filter_map(|o| o["metadata"].as_array())
            .flatten()
            .find(|m| m["key"] == "default.audio.sink")
            .and_then(|m| m["value"]["name"].as_str());
        let mut pinned = self.pinned.lock().unwrap_or_else(|e| e.into_inner());
        // If the chosen sink vanished, pin the actual fallback before a later
        // arrival can steal it back. Ask/Ignore then retain that fallback.
        let selected = target.or_else(|| {
            if pinned.as_ref().is_none_or(|name| {
                !sinks
                    .iter()
                    .any(|o| o["info"]["props"]["node.name"] == *name)
            }) {
                default_name
            } else {
                None
            }
        });
        if let Some(target) = selected {
            let node = match target {
                "speaker" | "headphones" => local.copied(),
                name => sinks
                    .iter()
                    .find(|o| o["info"]["props"]["node.name"] == name)
                    .copied(),
            }
            .ok_or_else(|| "audio device is no longer available".to_string())?;
            if target == "headphones" && !jack {
                return Err("headphones are no longer plugged in".into());
            }
            if target == "speaker" || target == "headphones" {
                let card = card.ok_or("local audio card unavailable")?;
                let route_name = if target == "speaker" {
                    "analog-output-speaker"
                } else {
                    "analog-output-headphones"
                };
                let route = card["info"]["params"]["EnumRoute"]
                    .as_array()
                    .and_then(|routes| routes.iter().find(|r| r["name"] == route_name))
                    .ok_or("audio route unavailable")?;
                let device = route["devices"]
                    .as_array()
                    .and_then(|d| d.first())
                    .and_then(Value::as_u64)
                    .ok_or("route device unavailable")?;
                pw_command(
                    "pw-cli",
                    &[
                        "set-param",
                        &card["id"].to_string(),
                        "Route",
                        &format!(
                            "{{ index: {}, device: {}, save: true }}",
                            route["index"], device
                        ),
                    ],
                )?;
            }
            let name = node["info"]["props"]["node.name"]
                .as_str()
                .ok_or("sink has no name")?;
            pw_command(
                "pw-metadata",
                &[
                    "-n",
                    "default",
                    "0",
                    "default.configured.audio.sink",
                    &json!({"name": name}).to_string(),
                    "Spa:String:JSON",
                ],
            )?;
            *pinned = node["info"]["props"]["node.name"]
                .as_str()
                .map(str::to_owned);
        }
        let active = sinks
            .iter()
            .find(|o| Some(o["info"]["props"]["node.name"].as_str().unwrap_or("")) == default_name);
        let active_route = card
            .and_then(|c| c["info"]["params"]["Route"].as_array())
            .and_then(|r| r.iter().find(|r| r["direction"] == "Output"));
        let kind = if active.is_some_and(|o| o["info"]["props"]["device.api"] == "bluez5") {
            "bluetooth"
        } else if active_route.is_some_and(|r| r["name"] == "analog-output-headphones") {
            "headphones"
        } else {
            "speaker"
        };
        let detected: Vec<_> = sinks.iter().filter(|o| o["info"]["props"]["device.api"] == "bluez5").map(|o| json!({
            "id": o["info"]["props"]["node.name"], "name": o["info"]["props"]["node.description"]
        })).collect();
        let mut fields = jack_status.fields();
        fields.extend(
            json!({"output": kind, "jack": jack, "ready": local.is_some(),
            "name": active.map(|o| &o["info"]["props"]["node.description"]), "sinks": detected})
            .as_object()
            .unwrap()
            .clone(),
        );
        Ok(fields)
    }
}

fn pw_command(command: &str, args: &[&str]) -> Result<(), String> {
    let output = std::process::Command::new(command)
        .args(args)
        .env("XDG_RUNTIME_DIR", crate::volume::Volume::runtime_dir())
        .output()
        .map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_owned())
    }
}

fn merge(into: &mut Value, update: Value) {
    if let (Some(dst), Some(src)) = (into.as_object_mut(), update.as_object()) {
        for (key, value) in src {
            if key == "metadata" {
                if let (Some(existing), Some(changes)) = (
                    dst.get_mut(key).and_then(Value::as_array_mut),
                    value.as_array(),
                ) {
                    for change in changes {
                        existing.retain(|m| {
                            m["subject"] != change["subject"] || m["key"] != change["key"]
                        });
                        if !change["value"].is_null() {
                            existing.push(change.clone());
                        }
                    }
                    continue;
                }
            }
            merge(dst.entry(key.clone()).or_insert(Value::Null), value.clone());
        }
    } else {
        *into = update;
    }
}

/// `/dev/input/eventN` for the jack, found by name under
/// `/sys/class/input`.
fn jack_device(input_class: &Path) -> Result<PathBuf, String> {
    let entries = fs::read_dir(input_class)
        .map_err(|e| format!("cannot read {}: {e}", input_class.display()))?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("event") {
            continue;
        }
        let label = fs::read_to_string(entry.path().join("device/name")).unwrap_or_default();
        if label.trim() == JACK_DEVICE_NAME {
            return Ok(PathBuf::from("/dev/input").join(&*name));
        }
    }
    Err("no headphone jack device".to_string())
}

/// `EVIOCGSW`: the current state of a device's switches, as a bitmask.
fn read_switch(node: &Path, switch: u32) -> Result<bool, String> {
    let file = fs::File::open(node).map_err(|e| format!("cannot open {}: {e}", node.display()))?;
    let mut mask = [0u8; SW_MASK_LEN];
    // EVIOCGSW(len) = _IOC(_IOC_READ, 'E', 0x1b, len)
    let request =
        (2u64 << 30 | (SW_MASK_LEN as u64) << 16 | (b'E' as u64) << 8 | 0x1b) as libc::c_ulong;
    // SAFETY: the buffer is exactly the length encoded in the request.
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), request, mask.as_mut_ptr()) };
    if rc < 0 {
        return Err(format!(
            "EVIOCGSW on {}: {}",
            node.display(),
            std::io::Error::last_os_error()
        ));
    }
    Ok(switch_set(&mask, switch))
}

fn switch_set(mask: &[u8], switch: u32) -> bool {
    let byte = (switch / 8) as usize;
    byte < mask.len() && mask[byte] & (1 << (switch % 8)) != 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monitor_shutdown_reaps_child_blocked_on_output_across_restarts() {
        for _ in 0..3 {
            let mut command = std::process::Command::new("sh");
            command.args([
                "-c",
                "printf '[{\"id\":7,\"info\":{\"state\":\"running\"}}]'; exec sleep 60",
            ]);
            let monitor = Monitor::start(command);
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            loop {
                if monitor.objects.lock().unwrap().contains_key(&7) {
                    break;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "monitor did not receive snapshot"
                );
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            let pid = monitor.child.lock().unwrap().as_ref().unwrap().id();
            let started = std::time::Instant::now();
            drop(monitor);
            assert!(started.elapsed() < std::time::Duration::from_secs(1));
            // waitpid must report ECHILD: Drop has already reaped this exact
            // child.
            let mut status = 0;
            assert_eq!(
                unsafe { libc::waitpid(pid as i32, &mut status, libc::WNOHANG) },
                -1
            );
            assert_eq!(
                std::io::Error::last_os_error().raw_os_error(),
                Some(libc::ECHILD)
            );
        }
    }

    #[test]
    fn monitor_shutdown_interrupts_failed_spawn_retry() {
        let command = std::process::Command::new("/nonexistent/tempo-pw-dump");
        let monitor = Monitor::start(command);
        std::thread::sleep(std::time::Duration::from_millis(30));
        let started = std::time::Instant::now();
        drop(monitor);
        assert!(started.elapsed() < std::time::Duration::from_millis(500));
    }

    #[test]
    fn monitor_deltas_preserve_default_sink_and_unmodified_properties() {
        let mut value = json!({"info": {"props": {"node.name": "speaker", "state": "idle"}},
            "metadata": [{"subject": 0, "key": "default.audio.sink", "value": {"name": "speaker"}}]});
        merge(
            &mut value,
            json!({"info": {"props": {"state": "running"}},
            "metadata": [{"subject": 0, "key": "default.configured.audio.sink", "value": {"name": "headset"}}]}),
        );
        assert_eq!(value["info"]["props"]["node.name"], "speaker");
        assert_eq!(value["info"]["props"]["state"], "running");
        assert_eq!(value["metadata"].as_array().unwrap().len(), 2);
        merge(
            &mut value,
            json!({"metadata": [{"subject": 0, "key": "default.audio.sink", "value": {"name": "headset"}}]}),
        );
        assert_eq!(value["metadata"].as_array().unwrap().len(), 2);
        assert_eq!(value["metadata"][1]["value"]["name"], "headset");
    }

    #[test]
    fn the_mask_bit() {
        assert!(!switch_set(&[0x00], SW_HEADPHONE_INSERT));
        assert!(switch_set(&[0x04], SW_HEADPHONE_INSERT));
        assert!(!switch_set(&[0x01], SW_HEADPHONE_INSERT));
        assert!(!switch_set(&[], SW_HEADPHONE_INSERT));
    }

    #[test]
    fn plugged_is_headphones() {
        let s = Status::from_jack(true);
        assert_eq!(s.output, Output::Headphones);
        assert_eq!(s.fields()["output"], json!("headphones"));
        assert_eq!(s.fields()["jack"], json!(true));
        assert_eq!(Status::from_jack(false).output, Output::Speaker);
    }

    #[test]
    fn finds_the_jack_by_name() {
        let dir = std::env::temp_dir().join(format!("tempod-output-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("event7/device")).unwrap();
        fs::write(dir.join("event7/device/name"), "gpio-keys\n").unwrap();
        fs::create_dir_all(dir.join("event3/device")).unwrap();
        fs::write(dir.join("event3/device/name"), "y2-cs43131 Headphone\n").unwrap();
        assert_eq!(
            jack_device(&dir).unwrap(),
            PathBuf::from("/dev/input/event3")
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn no_jack_is_an_error() {
        let dir = std::env::temp_dir().join(format!("tempod-nojack-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        assert!(status(&dir).is_err());
        fs::remove_dir_all(&dir).unwrap();
    }
}
