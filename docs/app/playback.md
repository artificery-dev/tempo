# Playback

The player hears music through libmpv, loaded over `dart:ffi` by the
`media_kit` package with no video surface and no platform plugin, which is
what lets the same code run whole under flutter-pi and in the emulator. mpv
picks its own output; on the device that is PipeWire in the `tempo` user's
session. Video goes a different way, through the flutter-pi GStreamer video
plugin, and FM radio does not touch the sound server at all. Around the
decoders sit the services the UI actually reads: what is playing, where the
sound goes, how loud it is, and the notices the panel shows while any of that
changes. The hardware path under all of this is in [Audio](../porting/audio.md),
the tuner in [FM](../porting/fm.md), and A2DP in [Bluetooth](../porting/bluetooth.md).

## Components

| Where | What |
| --- | --- |
| `packages/tempo_core/lib/src/services/playback.dart` | `NowPlaying`, the `PlaybackService` interface, `SilentPlayback` and `MediaKitPlayback`. |
| `packages/tempo_core/lib/src/services/serialized_playback.dart` | `SerializedPlayback`: one command at a time, from the wheel and the daemon alike. |
| `packages/tempo_core/lib/src/services/cadence_playback.dart` | `CadencePlayback`: resolves each track's path through Cadence just before opening it. |
| `packages/tempo_core/lib/src/services/video_playback.dart`, `screens/video.dart` | `VideoPlayback`, a session over `video_player`, and `playVideo`. |
| `packages/tempo_core/lib/src/services/fm_radio.dart`, `screens/fm_radio.dart` | `FmRadioService`, `DeviceFmRadio`, `FmRadioSession` and `openFmRadio`. |
| `packages/tempo_core/lib/src/services/output.dart` | `AudioOutput`, `OutputService`, `DeviceOutput` over tempod's `output` op. |
| `packages/tempo_core/lib/src/services/volume.dart` | `VolumeReading`, `VolumeService`, `DeviceVolume` over the `volume` op. |
| `packages/tempo_core/lib/src/services/feedback.dart` | `DeviceFeedback`: the `sound` and `haptic` ops for wheel words. |
| `packages/tempo_core/lib/src/osd.dart` | `Osd`, `OsdToast`, `VolumeToast`, `OutputToast`, `CardToast` and `OsdLayer`. |
| `packages/tempo_core/lib/src/audio_route_dialog.dart` | The Switch or Keep Current question for a new output. |
| `packages/tempo_core/lib/src/app.dart` | Rocker, media button and hold handling; the arrival listener; the toast widgets above the navigator. |
| `app/lib/src/flutter_player_service.dart` | `FlutterPlayerService`: the player as `tempod`'s `PlayerService`, for remote and Bluetooth control. |
| `daemon/native/src/output.rs`, `volume.rs` | The broker's PipeWire routing and mixer behind the two ops. |
| `daemon/lib/src/services/bluetooth_player.dart` | The MPRIS player BlueZ needs for AVRCP. |
| `app/flutter-pi/patches/0003-video-playbin-audio.patch` | The video plugin's `TEMPO_VIDEO_SIZE` and `TEMPO_VIDEO_STATS` handling. |

## The music player

`PlaybackService` is a `ValueListenable<NowPlaying>` with the click wheel's
words on it: `play(queue, index:)`, `toggle`, `setPlaying`, `seekTo`,
`seekBy`, `next`, `previous` and `stop`. `NowPlaying` carries the track, the
state, the position, the duration as the player found it or as the library
tagged it, and the index and count of the queue. Every implementation also
mirrors its state into `Playback.state`, which the status bar reads.

`MediaKitPlayback` makes one mpv `Player` with `vid=no`,
`audio-display=no`, `sub-auto=no` and `audio-file-auto=no`, so it decodes
sound only and never goes looking for the `.lrc` beside a song. Before that
it sets `LC_NUMERIC` back to `C` through libc, because libmpv parses its own
option strings with `strtod` and the frontend runs under `en_US.UTF-8`. It
opens the whole queue as an mpv playlist, so mpv moves from track to track by
itself; the end of the last entry is a `stop`. Position is published to the
second, `previous` restarts the track unless it is within the first three
seconds, and `next` at the end of the queue stops rather than wrapping.
`SilentPlayback` is the same state machine with no sound, used in tests and
by the emulator on a host without libmpv.

On the device the stack is built in `PlayerServices.device`:

| Layer | Role |
| --- | --- |
| `CadencePlayback` | Keeps the queue as library identities and resolves only the current item's path through `resolveLibraryPath` right before `play`, so a path is never held past the datastore generation it came from. It plays one track at a time in the delegate and moves on when the delegate empties. |
| `SerializedPlayback` | Runs every command after the last one finished, whether it came from the wheel, the daemon or Bluetooth. |
| `MediaKitPlayback` | libmpv. Replaced by `SilentPlayback` when the library cannot be loaded. |

`DaemonApp` stops playback whenever Cadence's attachment changes identity or
leaves the `attached` state, and before any card eject or profile move; see
[Cadence integration](cadence-integration.md).

## Video

`playVideo` disposes any earlier `VideoPlayback`, makes a new one with the
same path resolver, selects Home in the dock, ends the FM session, stops the
music player and only then plays. The session owns a `VideoPlayerController`
from `video_player`; on the device the platform implementation is
`flutterpi_gstreamer_video_player`, registered in `app/lib/main.dart`. A
video session survives navigation away from Home and holds `Playback.state`
and `VideoPlayback.keepAwake`, which the screen sleep timer honours while the
picture is playing. `next` on a video is `stop`; `previous` seeks to the
start.

Two environment variables reach the GStreamer plugin through the patch in
`app/flutter-pi/patches`. `TEMPO_VIDEO_SIZE=WIDTHxHEIGHT` inserts a
`videoscale` stage with borders so the texture uploaded to the panel is no
larger than the panel; `tempo.service` sets `480x360`. Any presence of
`TEMPO_VIDEO_STATS` logs the negotiated caps and sink statistics every five
seconds. In the emulator the volume is applied in software by following the
`VolumeSwitch`; on the device the hardware mixer applies to video as it does
to everything else.

## FM radio

`FmRadioSession` owns the dial: the frequency, the starred stations in the
applet's memory, seek state and a 120 ms tune settle timer. `openFmRadio`
reuses a live session for the same receiver, otherwise activates a new one,
disposes any video, selects Home, stops the music player and starts the
receiver. `DeviceFmRadio` speaks the `fm` op and polls it once a second while
a screen is listening so decoded RDS text appears. While a session is active
the media buttons drive it instead of the player: a press toggles power or
jumps between starred stations, a hold stops the session or seeks.

Music, video and FM are exclusive, and each entry point closes the others:

| Starting | Ends |
| --- | --- |
| Music | Nothing else is running; the music screens play into the shared service. |
| Video | The FM session, then the music player. |
| FM | Any video session, then the music player. |

## Output routing

`DeviceOutput` asks the broker's `output` op twice a second while anyone is
listening and publishes an `AudioOutput` of kind `speaker`, `headphones` or
`bluetooth` with the sink's name. The reply also lists the Bluetooth sinks
PipeWire currently has. The first reply is a baseline; after that a jack
change or a new sink id is pushed on `arrivals`.

`TempoApp` listens to `arrivals` and asks only when the arrival crosses
between local audio and Bluetooth: the broker's own route policy owns the
speaker to headphones switch. What happens then is the
`/settings/sound/output/on-new-device` setting, bound as
`output.onNewDevice`:

| Value | Behaviour |
| --- | --- |
| `switch` | `select` the new output at once. |
| `ask` | Wake the screen and show `AudioRouteDialog`; Switch selects, Keep Current or a back press does nothing. A newer arrival replaces an open question. |
| `ignore` | Nothing. |

`select` sends `{"op":"output","target":...}` with `speaker`, `headphones`
or a Bluetooth sink's node name, then re-reads. In the broker, a local target
sets the ALSA card's route to `analog-output-speaker` or
`analog-output-headphones` and every target pins
`default.configured.audio.sink` through `pw-metadata`; a headphones target
with nothing in the jack is refused, and a vanished sink makes the broker pin
whatever PipeWire fell back to so a later arrival cannot steal it back.
Route requests are queued in arrival order, and a failed one does not block
the next.

## Volume

`VolumeService` is a level from 0 to 100 and a mute flag, moved by `setLevel`
or by `nudge` in five percent steps. `DeviceVolume` moves its value at once,
so the rocker feels instant, and the broker catches up behind it: requests
are absolute levels, only one is in flight, and a newer level asked for while
one is out replaces it, so a run of presses lands as one climb. The reading
is polled twice a second so remote buttons and output changes show up, and a
poll never overwrites a request that is still pending. The `volume.level`
sink in the settings tree forwards a moved slider but ignores `system`
changes, which are the mixer's own reports.

A Bluetooth sink with AVRCP absolute volume reports `hardware: true` and its
device name. While the daemon has not yet said the remote transport is
Playing, an adjustment on such a sink is deferred; `setPlaybackActive` from
the owner connection releases it, and a deferred level is dropped if the
device changed in the meantime so a headset's level is never applied to the
speaker. `setLevelConfirmed`, used for daemon commands, fails when the level
cannot be confirmed for that reason.

## Remote and Bluetooth control

`FlutterPlayerService` is the one `PlayerService` the daemon sees. It
snapshots the music player, the volume and whether video or FM is active;
during either it reports `available: false`, and commands are refused with
`player_unavailable`. `DaemonApp` connects it to `tempod`'s `/api/v1/owner`
WebSocket with the owner credential, and the daemon's `BluetoothPlayer`
publishes that state as an MPRIS player at `/org/tempo/player` so BlueZ
reports Playing and accepts the headset's buttons. Without the owner
credential the app logs that remote playback is unavailable and plays
locally. The daemon side is in [Radio hosting](../daemon/radios.md).

## Feedback

`DeviceFeedback` answers each wheel word with a `sound` op named `tick`,
`click` or `thump` and a `haptic` op, sent and forgotten. The settings under
Controls choose whether sounds play, whether they stay on the speaker when
headphones are in, which sound is used for every word, and a `soft`,
`standard` or `strong` motor feel; `soft` and `strong` send explicit
durations of 20, 30 and 65 ms or 40, 65 and 130 ms because the motor's
strength range is narrow.

## The OSD

`Osd` is one slot: `show` puts a builder up and restarts a 1.5 s clock, and
`OsdLayer`, mounted above the navigator, fades it in and out over 150 ms and
leaves the tree when the slot is empty. Every notice wears `OsdToast`, a
glyph, a body and a short trailing word on the theme's neutral surface.

| Notice | Shown by | When |
| --- | --- | --- |
| `VolumeToast` | `VolumeToasts`, and the rocker handler | The level moves, from the rocker, the wheel, a remote command or a Bluetooth report. A square card with the level glyph over an `OsdBar`; a Bluetooth sink adds its name and `Player` when the level is software-only. Only while the screen is awake; a pocket press moves the level with the panel dark. |
| `OutputToast` | `OutputToasts` | The output value changes: speaker, headphones or the Bluetooth device's name. |
| `CardToast` | `CardToasts` | A card comes or goes after startup; the first reading is the baseline. |

The time zone binding uses the same slot for its failure notice.
