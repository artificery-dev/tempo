//! The `sound` op: the tick, the click and the thump that answer the
//! wheel, played through the sound server.
//!
//! The sounds are synthesized here rather than shipped: a click is a short
//! damped burst, a tick a shorter and softer one, a thump lower and
//! longer. The speaker-only option uses a targeted pipewire-alsa PCM
//! to keep feedback on the built-in
//! audio device even when Bluetooth is the default music output.
//! Because speaker and headphones share a DAC, feedback is suppressed
//! while the headphone jack is occupied in that mode. Otherwise clicks
//! use the default audio output.
//! The PCM is opened once and kept; between sounds
//! it runs dry, which ALSA reports as an underrun and which the next
//! sound recovers from with one prepare. That keeps a sound's latency to
//! the buffer's own depth rather than a connection's.

use std::{f32::consts::PI, path::Path, sync::Mutex};

use alsa::{
    Direction, ValueOr,
    pcm::{Access, Format, Frames, HwParams, PCM, State},
};

use crate::output;

// Use the stable PipeWire node name, never a numeric ID (IDs change on
// reconnect). This selects only this PCM's destination, not the music sink.
const DEVICE: &str = "pipewire:NODE=alsa_output.platform-sound.stereo-fallback,ROLE=Notification";
const RATE: u32 = 48_000;
/// Frames per period: 5 ms.
const PERIOD: Frames = 240;
/// Frames in the ring: four periods, 20 ms.
const BUFFER: Frames = PERIOD * 4;

/// A named sound.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Name {
    Tick,
    Click,
    Thump,
}

impl Name {
    pub fn parse(name: &str) -> Option<Name> {
        match name {
            "tick" => Some(Name::Tick),
            "click" => Some(Name::Click),
            "thump" => Some(Name::Thump),
            _ => None,
        }
    }
}

/// Synthesize a sound: a sine at `hz` that decays over `ms`, scaled to
/// `level` of full scale, in signed 16-bit mono at [`RATE`].
fn synthesize(hz: f32, ms: u32, level: f32) -> Vec<i16> {
    let frames = (RATE * ms / 1000) as usize;
    (0..frames)
        .map(|i| {
            let t = i as f32 / RATE as f32;
            let envelope = (-t * 1000.0 / (ms as f32 / 4.0)).exp();
            (level * envelope * (2.0 * PI * hz * t).sin() * i16::MAX as f32) as i16
        })
        .collect()
}

pub fn samples(name: Name) -> Vec<i16> {
    match name {
        Name::Tick => synthesize(3200.0, 6, 0.35),
        Name::Click => synthesize(1800.0, 14, 0.6),
        Name::Thump => synthesize(220.0, 60, 0.7),
    }
}

/// The PCM as a resource, opened on first use and kept.
pub struct Sound {
    inner: Mutex<Option<(bool, PCM)>>,
    sounds: [Vec<i16>; 3],
}

impl Default for Sound {
    fn default() -> Sound {
        Sound::new()
    }
}

impl Sound {
    pub fn new() -> Sound {
        Sound {
            inner: Mutex::new(None),
            sounds: [
                samples(Name::Tick),
                samples(Name::Click),
                samples(Name::Thump),
            ],
        }
    }

    pub fn play(&self, name: Name, speaker_only: bool) -> Result<(), String> {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        // The local sink switches to headphones on insertion. Do not force
        // the shared DAC into speaker mode or send feedback into that path.
        // A failed jack read also suppresses feedback rather than guessing.
        if speaker_only && output::status(Path::new("/sys/class/input"))?.jack {
            *guard = None;
            return Ok(());
        }
        if guard
            .as_ref()
            .is_some_and(|(route, _)| *route != speaker_only)
        {
            *guard = None;
        }
        if guard.is_none() {
            *guard = Some((speaker_only, open(speaker_only)?));
        }
        let (_, pcm) = guard.as_ref().expect("opened above");
        let data = &self.sounds[name as usize];
        match write(pcm, data) {
            Ok(()) => Ok(()),
            Err(e) => {
                // The server may have gone away under us; open afresh next
                // time.
                *guard = None;
                Err(e)
            }
        }
    }
}

fn open(speaker_only: bool) -> Result<PCM, String> {
    let device = if speaker_only { DEVICE } else { "default" };
    let pcm = PCM::new(device, Direction::Playback, false)
        .map_err(|e| format!("cannot open {device}: {e}"))?;
    {
        let hw = HwParams::any(&pcm).map_err(|e| format!("hw params: {e}"))?;
        hw.set_channels(1).map_err(|e| format!("channels: {e}"))?;
        hw.set_rate(RATE, ValueOr::Nearest)
            .map_err(|e| format!("rate: {e}"))?;
        hw.set_format(Format::s16())
            .map_err(|e| format!("format: {e}"))?;
        hw.set_access(Access::RWInterleaved)
            .map_err(|e| format!("access: {e}"))?;
        hw.set_period_size_near(PERIOD, ValueOr::Nearest)
            .map_err(|e| format!("period: {e}"))?;
        hw.set_buffer_size_near(BUFFER)
            .map_err(|e| format!("buffer: {e}"))?;
        pcm.hw_params(&hw).map_err(|e| format!("hw params: {e}"))?;
    }
    Ok(pcm)
}

fn write(pcm: &PCM, data: &[i16]) -> Result<(), String> {
    match pcm.state() {
        State::Running | State::Prepared => {}
        // Ran dry since the last sound, or never started: one prepare.
        _ => pcm.prepare().map_err(|e| format!("prepare: {e}"))?,
    }
    let io = pcm.io_i16().map_err(|e| format!("io: {e}"))?;
    let mut written = 0;
    while written < data.len() {
        match io.writei(&data[written..]) {
            Ok(n) => written += n,
            Err(e) => {
                pcm.try_recover(e, true)
                    .map_err(|e| format!("write: {e}"))?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(Name::parse("tick"), Some(Name::Tick));
        assert_eq!(Name::parse("thump"), Some(Name::Thump));
        assert!(Name::parse("bang").is_none());
    }

    #[test]
    fn the_sounds_are_short_and_decay() {
        let click = samples(Name::Click);
        assert_eq!(click.len(), 48 * 14);
        let head: i32 = click[..48].iter().map(|s| (*s as i32).abs()).max().unwrap();
        let tail: i32 = click[click.len() - 48..]
            .iter()
            .map(|s| (*s as i32).abs())
            .max()
            .unwrap();
        assert!(head > tail * 4, "decays: {head} vs {tail}");
        assert!(samples(Name::Tick).len() < click.len());
        assert!(samples(Name::Thump).len() > click.len());
    }
}
