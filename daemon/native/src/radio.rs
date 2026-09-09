//! The MT6627 FM receiver and its direct audio path.
//!
//! The vendor FM character device owns RF tuning and parses RDS in-kernel.
//! Audio does not travel through that device: the chip is a 32 kHz I2S
//! master, and the MT6582 AFE routes it directly through ASRC/gain2 to the
//! CS43131.  A silent 48 kHz playback stream keeps that output clocked while
//! the `FM Playback Switch` mixer control connects the direct path.

use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    mem::{size_of, zeroed},
    os::fd::AsRawFd,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use alsa::{
    Direction, ValueOr,
    ctl::{Ctl, ElemId, ElemIface, ElemType, ElemValue},
    pcm::{Access, Format, Frames, HwParams, PCM},
};
use serde_json::{Map, Value, json};

const DEVICE: &str = "/dev/fm";
// Use the sound server, not the raw hw PCM. tempod's click stream already
// keeps PipeWire attached to the card, so opening hw: directly would race the
// owner we deliberately installed. Continuous silence through `default`
// keeps the same AFE/DAC clock running and mixes with the direct FM route.
const PCM_DEVICE: &str = "default";
const CTL_DEVICE: &str = "hw:y2cs43131";
const ROUTE_CONTROL: &str = "FM Playback Switch";

pub const MIN_FREQUENCY_KHZ: i64 = 87_500;
pub const MAX_FREQUENCY_KHZ: i64 = 108_000;
pub const FREQUENCY_STEP_KHZ: i64 = 100;
const DEFAULT_FREQUENCY_KHZ: i64 = 95_500;

const FM_MAGIC: u8 = 0xf5;
const FM_BAND_UE: u8 = 1;
const FM_SPACE_100K: u8 = 1;
const FM_ANA_LONG: i32 = 0;

const IOCTL_POWERUP: u8 = 0;
const IOCTL_POWERDOWN: u8 = 1;
const IOCTL_TUNE: u8 = 2;
const IOCTL_SEEK: u8 = 3;
const IOCTL_GET_RSSI: u8 = 7;
const IOCTL_GET_MONO_STEREO: u8 = 13;
const IOCTL_RDS_ONOFF: u8 = 18;
const IOCTL_ANA_SWITCH: u8 = 30;

const RDS_EVENT_PI_CODE: u16 = 0x0002;
const RDS_EVENT_PTY_CODE: u16 = 0x0004;
const RDS_EVENT_PROGRAM_NAME: u16 = 0x0008;
const RDS_EVENT_LAST_RADIO_TEXT: u16 = 0x0040;

const RATE: u32 = 48_000;
const CHANNELS: usize = 2;
const PERIOD: Frames = 240;
const BUFFER: Frames = PERIOD * 4;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Request {
    pub on: Option<bool>,
    pub frequency_khz: Option<i64>,
    /// Signed direction: -1 seeks down the band, +1 seeks up.
    pub seek: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub available: bool,
    pub on: bool,
    pub frequency_khz: i64,
    pub rssi: Option<i32>,
    pub stereo: Option<bool>,
    pub program_name: Option<String>,
    pub radio_text: Option<String>,
    pub pi: Option<u16>,
    pub pty: Option<u8>,
}

impl Status {
    pub fn fields(&self) -> Map<String, Value> {
        let mut fields = Map::new();
        fields.insert("available".into(), json!(self.available));
        fields.insert("on".into(), json!(self.on));
        fields.insert("frequency_khz".into(), json!(self.frequency_khz));
        if let Some(rssi) = self.rssi {
            fields.insert("rssi".into(), json!(rssi));
        }
        if let Some(stereo) = self.stereo {
            fields.insert("stereo".into(), json!(stereo));
        }
        if let Some(name) = &self.program_name {
            fields.insert("program_name".into(), json!(name));
        }
        if let Some(text) = &self.radio_text {
            fields.insert("radio_text".into(), json!(text));
        }
        if let Some(pi) = self.pi {
            fields.insert("pi".into(), json!(pi));
        }
        if let Some(pty) = self.pty {
            fields.insert("pty".into(), json!(pty));
        }
        fields
    }
}

#[derive(Default)]
struct Metadata {
    program_name: Option<String>,
    radio_text: Option<String>,
    pi: Option<u16>,
    pty: Option<u8>,
}

struct Active {
    device: File,
    carrier: Carrier,
    frequency_khz: i64,
    rssi: Option<i32>,
    stereo: Option<bool>,
    metadata: Metadata,
}

struct Inner {
    active: Option<Active>,
    last_frequency_khz: i64,
}

/// Serialized ownership of the receiver, AFE route, and clocking PCM.
pub struct Radio {
    inner: Mutex<Inner>,
    device: PathBuf,
    pcm_device: String,
    ctl_device: String,
}

impl Default for Radio {
    fn default() -> Radio {
        Radio::new()
    }
}

impl Radio {
    pub fn new() -> Radio {
        Radio {
            inner: Mutex::new(Inner {
                active: None,
                last_frequency_khz: DEFAULT_FREQUENCY_KHZ,
            }),
            device: PathBuf::from(DEVICE),
            pcm_device: PCM_DEVICE.into(),
            ctl_device: CTL_DEVICE.into(),
        }
    }

    pub fn apply(&self, request: &Request) -> Result<Status, String> {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());

        if request.frequency_khz.is_some() && request.seek.is_some() {
            return Err("frequency_khz and seek cannot be used together".to_string());
        }

        if request.on == Some(false) {
            self.disable(&mut inner)?;
            return Ok(self.status(&mut inner));
        }

        let requested_frequency = request.frequency_khz.map(validate_frequency).transpose()?;
        let requested_seek = request.seek.map(validate_seek_direction).transpose()?;

        if request.on == Some(true) && inner.active.is_none() {
            let frequency = requested_frequency.unwrap_or(inner.last_frequency_khz);
            inner.active = Some(self.enable(frequency)?);
            inner.last_frequency_khz = frequency;
        } else if let Some(frequency) = requested_frequency {
            let active = inner
                .active
                .as_mut()
                .ok_or_else(|| "radio is off".to_string())?;
            tune(active, frequency)?;
            inner.last_frequency_khz = active.frequency_khz;
        }

        if let Some(direction) = requested_seek {
            let active = inner
                .active
                .as_mut()
                .ok_or_else(|| "radio is off".to_string())?;
            seek(active, direction)?;
            inner.last_frequency_khz = active.frequency_khz;
        }

        Ok(self.status(&mut inner))
    }

    fn enable(&self, frequency_khz: i64) -> Result<Active, String> {
        let device = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&self.device)
            .map_err(|e| format!("cannot open {}: {e}", self.device.display()))?;

        let mut antenna = FM_ANA_LONG;
        ioctl(&device, IOCTL_ANA_SWITCH, &mut antenna)?;

        let mut parameters = TuneParameters::new(frequency_khz);
        ioctl(&device, IOCTL_POWERUP, &mut parameters)?;
        if parameters.error != 0 {
            return Err(format!(
                "power-up at {:.1} MHz failed ({})",
                frequency_khz as f64 / 1000.0,
                parameters.error
            ));
        }

        let carrier = match Carrier::start(&self.pcm_device) {
            Ok(carrier) => carrier,
            Err(error) => {
                power_down(&device);
                return Err(error);
            }
        };

        if let Err(error) = set_route(&self.ctl_device, true) {
            carrier.stop();
            power_down(&device);
            return Err(error);
        }

        let mut rds_on = 1u16;
        if let Err(error) = ioctl(&device, IOCTL_RDS_ONOFF, &mut rds_on) {
            log!("fm", "RDS unavailable: {error}");
        }

        let mut active = Active {
            device,
            carrier,
            frequency_khz: i64::from(parameters.frequency) * FREQUENCY_STEP_KHZ,
            rssi: None,
            stereo: None,
            metadata: Metadata::default(),
        };
        thread::sleep(Duration::from_millis(60));
        refresh_signal(&mut active);
        log!(
            "fm",
            "on at {:.1} MHz, RSSI {}",
            active.frequency_khz as f64 / 1000.0,
            active
                .rssi
                .map(|value| value.to_string())
                .unwrap_or_else(|| "unknown".into())
        );
        Ok(active)
    }

    fn disable(&self, inner: &mut Inner) -> Result<(), String> {
        let Some(active) = inner.active.take() else {
            return Ok(());
        };
        inner.last_frequency_khz = active.frequency_khz;

        let mut errors = Vec::new();
        if let Err(error) = set_route(&self.ctl_device, false) {
            errors.push(error);
        }
        active.carrier.stop();
        if let Err(error) = power_down_result(&active.device) {
            errors.push(error);
        }
        log!("fm", "off");
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }

    fn status(&self, inner: &mut Inner) -> Status {
        let available = self.device.exists();
        let Some(active) = inner.active.as_mut() else {
            return Status {
                available,
                on: false,
                frequency_khz: inner.last_frequency_khz,
                rssi: None,
                stereo: None,
                program_name: None,
                radio_text: None,
                pi: None,
                pty: None,
            };
        };

        refresh_signal(active);
        read_rds(active);
        Status {
            available,
            on: true,
            frequency_khz: active.frequency_khz,
            rssi: active.rssi,
            stereo: active.stereo,
            program_name: active.metadata.program_name.clone(),
            radio_text: active.metadata.radio_text.clone(),
            pi: active.metadata.pi,
            pty: active.metadata.pty,
        }
    }
}

impl Drop for Radio {
    fn drop(&mut self) {
        let ctl_device = self.ctl_device.clone();
        let inner = self.inner.get_mut().unwrap_or_else(|e| e.into_inner());
        if let Some(active) = inner.active.take() {
            let _ = set_route(&ctl_device, false);
            active.carrier.stop();
            power_down(&active.device);
        }
    }
}

fn validate_frequency(frequency_khz: i64) -> Result<i64, String> {
    if !(MIN_FREQUENCY_KHZ..=MAX_FREQUENCY_KHZ).contains(&frequency_khz) {
        return Err(format!(
            "frequency must be {MIN_FREQUENCY_KHZ}..={MAX_FREQUENCY_KHZ} kHz"
        ));
    }
    if frequency_khz % FREQUENCY_STEP_KHZ != 0 {
        return Err(format!(
            "frequency must be a multiple of {FREQUENCY_STEP_KHZ} kHz"
        ));
    }
    Ok(frequency_khz)
}

fn validate_seek_direction(direction: i64) -> Result<i64, String> {
    match direction {
        -1 | 1 => Ok(direction),
        _ => Err("seek must be -1 (down) or 1 (up)".to_string()),
    }
}

fn tune(active: &mut Active, frequency_khz: i64) -> Result<(), String> {
    let mut parameters = TuneParameters::new(frequency_khz);
    ioctl(&active.device, IOCTL_TUNE, &mut parameters)?;
    if parameters.error != 0 {
        return Err(format!(
            "tune at {:.1} MHz failed ({})",
            frequency_khz as f64 / 1000.0,
            parameters.error
        ));
    }
    active.frequency_khz = i64::from(parameters.frequency) * FREQUENCY_STEP_KHZ;
    active.metadata = Metadata::default();
    thread::sleep(Duration::from_millis(60));
    refresh_signal(active);
    log!(
        "fm",
        "tuned {:.1} MHz, RSSI {}",
        active.frequency_khz as f64 / 1000.0,
        active
            .rssi
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown".into())
    );
    Ok(())
}

fn seek(active: &mut Active, direction: i64) -> Result<(), String> {
    let mut parameters = SeekParameters::new(active.frequency_khz, direction);
    ioctl(&active.device, IOCTL_SEEK, &mut parameters)?;
    if parameters.error != 0 {
        return Err(format!(
            "seek {} from {:.1} MHz failed ({})",
            if direction > 0 { "up" } else { "down" },
            active.frequency_khz as f64 / 1000.0,
            parameters.error
        ));
    }

    let frequency_khz = i64::from(parameters.frequency) * FREQUENCY_STEP_KHZ;
    active.frequency_khz = validate_frequency(frequency_khz).map_err(|_| {
        format!(
            "seek returned an invalid frequency ({})",
            parameters.frequency
        )
    })?;
    active.metadata = Metadata::default();
    thread::sleep(Duration::from_millis(60));
    refresh_signal(active);
    log!(
        "fm",
        "sought {} to {:.1} MHz, RSSI {}",
        if direction > 0 { "up" } else { "down" },
        active.frequency_khz as f64 / 1000.0,
        active
            .rssi
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown".into())
    );
    Ok(())
}

fn refresh_signal(active: &mut Active) {
    let mut rssi = 0i32;
    if ioctl(&active.device, IOCTL_GET_RSSI, &mut rssi).is_ok() {
        active.rssi = Some(rssi);
    }
    let mut stereo = 0u16;
    if ioctl(&active.device, IOCTL_GET_MONO_STEREO, &mut stereo).is_ok() {
        active.stereo = Some(stereo != 0);
    }
}

fn read_rds(active: &mut Active) {
    // SAFETY: RdsData is a C-layout aggregate containing only integer fields.
    let mut data: RdsData = unsafe { zeroed() };
    // The vendor driver intentionally makes this read nonblocking: zero means
    // no RDS event has completed since the previous read.
    let read = unsafe {
        libc::read(
            active.device.as_raw_fd(),
            (&mut data as *mut RdsData).cast(),
            size_of::<RdsData>(),
        )
    };
    if read == 0 {
        return;
    }
    if read < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::WouldBlock {
            log!("fm", "RDS read: {error}");
        }
        return;
    }
    if read as usize != size_of::<RdsData>() {
        log!(
            "fm",
            "RDS read returned {read} bytes, expected {}",
            size_of::<RdsData>()
        );
        return;
    }

    if data.event_status & RDS_EVENT_PROGRAM_NAME != 0 {
        active.metadata.program_name = rds_string(&data.ps_data.ps[3]);
    }
    if data.event_status & RDS_EVENT_LAST_RADIO_TEXT != 0 {
        let length = usize::from(data.rt_data.text_length).min(64);
        active.metadata.radio_text = rds_string(&data.rt_data.text_data[3][..length]);
    }
    if data.event_status & RDS_EVENT_PI_CODE != 0 {
        active.metadata.pi = Some(data.pi);
    }
    if data.event_status & RDS_EVENT_PTY_CODE != 0 {
        active.metadata.pty = Some(data.pty);
    }
}

fn rds_string(bytes: &[u8]) -> Option<String> {
    let text: String = bytes
        .iter()
        .take_while(|byte| **byte != b'\r' && **byte != 0)
        .map(|byte| match *byte {
            0x20..=0x7e => char::from(*byte),
            0xa0..=0xff => char::from(*byte),
            _ => ' ',
        })
        .collect();
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

#[repr(C)]
struct TuneParameters {
    error: u8,
    band: u8,
    spacing: u8,
    hilo: u8,
    frequency: u16,
}

impl TuneParameters {
    fn new(frequency_khz: i64) -> TuneParameters {
        TuneParameters {
            error: 0,
            band: FM_BAND_UE,
            spacing: FM_SPACE_100K,
            hilo: 0,
            frequency: (frequency_khz / FREQUENCY_STEP_KHZ) as u16,
        }
    }
}

/// The legacy `struct fm_seek_parm`; unlike the newer seek ABI it carries no
/// userspace pointers, so it is stable across this 32-bit boundary.
#[repr(C)]
struct SeekParameters {
    error: u8,
    band: u8,
    spacing: u8,
    hilo: u8,
    direction: u8,
    threshold: u8,
    frequency: u16,
}

impl SeekParameters {
    fn new(frequency_khz: i64, direction: i64) -> SeekParameters {
        SeekParameters {
            error: 0,
            band: FM_BAND_UE,
            spacing: FM_SPACE_100K,
            hilo: 0,
            // The vendor ABI calls upward 0 and downward 1.
            direction: u8::from(direction < 0),
            threshold: 0,
            frequency: (frequency_khz / FREQUENCY_STEP_KHZ) as u16,
        }
    }
}

fn ioctl<T>(device: &File, number: u8, value: &mut T) -> Result<(), String> {
    let request = ioctl_request(number);
    // SAFETY: every request here is _IOWR and receives the exact C-layout
    // scalar/structure that the request number names in fm_ioctl.h.
    let result = unsafe { libc::ioctl(device.as_raw_fd(), request, value as *mut T) };
    if result < 0 {
        Err(format!(
            "FM ioctl {number}: {}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}

fn ioctl_request(number: u8) -> libc::c_ulong {
    // The vendor ABI declared pointer types in _IOWR, so the encoded size is
    // the target architecture's pointer width (4 on the ARMv7 player).
    ((3u64 << 30)
        | ((size_of::<*mut libc::c_void>() as u64) << 16)
        | ((FM_MAGIC as u64) << 8)
        | u64::from(number)) as libc::c_ulong
}

fn power_down(device: &File) {
    let _ = power_down_result(device);
}

fn power_down_result(device: &File) -> Result<(), String> {
    let mut value = 0i32;
    ioctl(device, IOCTL_POWERDOWN, &mut value)
}

fn set_route(device: &str, enabled: bool) -> Result<(), String> {
    let ctl =
        Ctl::new(device, false).map_err(|e| format!("cannot open ALSA control {device}: {e}"))?;
    let mut id = ElemId::new(ElemIface::Mixer);
    let name = CString::new(ROUTE_CONTROL).expect("static mixer name has no NUL");
    id.set_name(&name);
    let mut value = ElemValue::new(ElemType::Boolean)
        .map_err(|e| format!("cannot allocate ALSA control value: {e}"))?;
    value.set_id(&id);
    value
        .set_boolean(0, enabled)
        .ok_or_else(|| "FM route is not a boolean control".to_string())?;
    ctl.elem_write(&value)
        .map_err(|e| format!("cannot set {ROUTE_CONTROL}: {e}"))
}

struct Carrier {
    stop: Arc<AtomicBool>,
    thread: JoinHandle<()>,
}

impl Carrier {
    fn start(device: &str) -> Result<Carrier, String> {
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let device = device.to_string();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("fm-carrier".into())
            .spawn(move || carrier_thread(&device, worker_stop, ready_tx))
            .map_err(|e| format!("cannot start FM audio carrier: {e}"))?;

        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(Ok(())) => Ok(Carrier { stop, thread }),
            Ok(Err(error)) => {
                let _ = thread.join();
                Err(error)
            }
            Err(error) => {
                stop.store(true, Ordering::Release);
                let _ = thread.join();
                Err(format!("FM audio carrier did not start: {error}"))
            }
        }
    }

    fn stop(self) {
        self.stop.store(true, Ordering::Release);
        if self.thread.join().is_err() {
            log!("fm", "audio carrier thread panicked");
        }
    }
}

fn carrier_thread(
    device: &str,
    stop: Arc<AtomicBool>,
    ready: mpsc::SyncSender<Result<(), String>>,
) {
    let pcm = match open_carrier(device) {
        Ok(pcm) => pcm,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    let io = match pcm.io_i16() {
        Ok(io) => io,
        Err(error) => {
            let _ = ready.send(Err(format!("FM audio carrier I/O: {error}")));
            return;
        }
    };
    if ready.send(Ok(())).is_err() {
        return;
    }

    let silence = vec![0i16; PERIOD as usize * CHANNELS];
    while !stop.load(Ordering::Acquire) {
        if let Err(error) = io.writei(&silence) {
            if let Err(recovery) = pcm.try_recover(error, true) {
                log!("fm", "audio carrier stopped: {recovery}");
                break;
            }
        }
    }
    let _ = pcm.drop();
}

fn open_carrier(device: &str) -> Result<PCM, String> {
    let pcm = PCM::new(device, Direction::Playback, false)
        .map_err(|e| format!("cannot open FM audio carrier {device}: {e}"))?;
    {
        let hw = HwParams::any(&pcm).map_err(|e| format!("FM carrier hw params: {e}"))?;
        hw.set_channels(CHANNELS as u32)
            .map_err(|e| format!("FM carrier channels: {e}"))?;
        hw.set_rate(RATE, ValueOr::Nearest)
            .map_err(|e| format!("FM carrier rate: {e}"))?;
        hw.set_format(Format::s16())
            .map_err(|e| format!("FM carrier format: {e}"))?;
        hw.set_access(Access::RWInterleaved)
            .map_err(|e| format!("FM carrier access: {e}"))?;
        hw.set_period_size_near(PERIOD, ValueOr::Nearest)
            .map_err(|e| format!("FM carrier period: {e}"))?;
        hw.set_buffer_size_near(BUFFER)
            .map_err(|e| format!("FM carrier buffer: {e}"))?;
        pcm.hw_params(&hw)
            .map_err(|e| format!("FM carrier hw params: {e}"))?;
    }
    pcm.prepare()
        .map_err(|e| format!("FM carrier prepare: {e}"))?;
    Ok(pcm)
}

// The vendor driver copies this complete structure from read(/dev/fm).
// `c_ulong` is intentional: its size is part of the old 32-bit ABI.
#[allow(dead_code)]
#[repr(C)]
struct RdsClockTime {
    month: u16,
    day: u16,
    year: u16,
    hour: u16,
    minute: u16,
    local_time_offset_sign: u8,
    local_time_offset_half_hour: u8,
}

#[allow(dead_code)]
#[repr(C)]
struct RdsFlags {
    tp: u8,
    ta: u8,
    music: u8,
    stereo: u8,
    artificial_head: u8,
    compressed: u8,
    dynamic_pty: u8,
    text_ab: u8,
    status: u32,
}

#[allow(dead_code)]
#[repr(C)]
struct RdsAlternativeFrequencies {
    count: i16,
    frequencies: [[i16; 25]; 2],
    address_count: u8,
    method_a: u8,
    count_received: u8,
}

#[allow(dead_code)]
#[repr(C)]
struct RdsProgramService {
    ps: [[u8; 8]; 4],
    address_count: u8,
}

#[allow(dead_code)]
#[repr(C)]
struct RdsRadioText {
    text_data: [[u8; 64]; 4],
    get_length: u8,
    is_display: u8,
    text_length: u8,
    is_type_a: u8,
    buffer_count: u8,
    address_count: u16,
}

#[allow(dead_code)]
#[repr(C)]
struct RdsGroupCount {
    total: libc::c_ulong,
    group_a: [libc::c_ulong; 16],
    group_b: [libc::c_ulong; 16],
}

#[allow(dead_code)]
#[repr(C)]
struct RdsData {
    clock_time: RdsClockTime,
    flags: RdsFlags,
    pi: u16,
    switch_tp: u8,
    pty: u8,
    alternative_frequencies: RdsAlternativeFrequencies,
    alternative_frequencies_other_network: RdsAlternativeFrequencies,
    radio_page_code: u8,
    program_item_number_code: u16,
    extended_country_code: u8,
    language_code: u16,
    ps_data: RdsProgramService,
    ps_other_network: [u8; 8],
    rt_data: RdsRadioText,
    event_status: u16,
    group_count: RdsGroupCount,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_the_us_europe_channel_grid() {
        assert_eq!(validate_frequency(87_500), Ok(87_500));
        assert_eq!(validate_frequency(95_500), Ok(95_500));
        assert_eq!(validate_frequency(108_000), Ok(108_000));
        assert!(validate_frequency(87_400).is_err());
        assert!(validate_frequency(108_100).is_err());
        assert!(validate_frequency(95_550).is_err());
    }

    #[test]
    fn tune_parameter_layout_matches_the_vendor_abi() {
        assert_eq!(size_of::<TuneParameters>(), 6);
        let parameters = TuneParameters::new(95_500);
        assert_eq!(parameters.frequency, 955);
        assert_eq!(parameters.band, FM_BAND_UE);
        assert_eq!(parameters.spacing, FM_SPACE_100K);
    }

    #[test]
    fn seek_parameter_layout_matches_the_vendor_abi() {
        assert_eq!(size_of::<SeekParameters>(), 8);
        let up = SeekParameters::new(95_500, 1);
        assert_eq!(up.frequency, 955);
        assert_eq!(up.direction, 0);
        assert_eq!(up.spacing, FM_SPACE_100K);
        let down = SeekParameters::new(95_500, -1);
        assert_eq!(down.direction, 1);
        assert_eq!(
            validate_seek_direction(0),
            Err("seek must be -1 (down) or 1 (up)".into())
        );
    }

    #[test]
    fn ioctl_encodes_the_pointer_size_like_the_vendor_header() {
        assert_eq!(ioctl_request(IOCTL_TUNE) & 0xff, u64::from(IOCTL_TUNE));
        assert_eq!((ioctl_request(IOCTL_TUNE) >> 8) & 0xff, u64::from(FM_MAGIC));
        assert_eq!(
            (ioctl_request(IOCTL_TUNE) >> 16) & 0x3fff,
            size_of::<*mut libc::c_void>() as libc::c_ulong
        );
    }

    #[test]
    fn rds_layout_tracks_the_native_ulong_abi() {
        let expected = if size_of::<libc::c_ulong>() == 4 {
            688
        } else {
            824
        };
        assert_eq!(size_of::<RdsData>(), expected);
    }

    #[test]
    fn cleans_rds_text_for_json_and_display() {
        assert_eq!(rds_string(b"  WXYZ FM  "), Some("WXYZ FM".into()));
        assert_eq!(
            rds_string(b"Track title\rgarbage"),
            Some("Track title".into())
        );
        assert_eq!(rds_string(b"        "), None);
    }

    #[test]
    fn status_fields_omit_data_the_station_has_not_sent() {
        let fields = Status {
            available: true,
            on: true,
            frequency_khz: 95_500,
            rssi: Some(-70),
            stereo: Some(true),
            program_name: None,
            radio_text: Some("Artist - Track".into()),
            pi: None,
            pty: None,
        }
        .fields();
        assert_eq!(fields["frequency_khz"], json!(95_500));
        assert_eq!(fields["radio_text"], json!("Artist - Track"));
        assert!(!fields.contains_key("program_name"));
    }
}
