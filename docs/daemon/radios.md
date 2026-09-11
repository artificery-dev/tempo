# Radio hosting

The player never drives a radio itself. FM tuning is an op on the native
broker's socket, because `/dev/fm` and the ALSA control are root's. WiFi and
Bluetooth pairing are typed commands on the Dart daemon's HTTP API, because
they are sequences of `wpa_cli` and `bluetoothctl` calls that must not run
on the UI isolate. Bluetooth playback control runs the other way: the Dart
daemon registers an AVRCP player with BlueZ so the peer's buttons reach the
playback owner. This page is about how those three are structured and
sequenced inside `tempod`. The hardware and the userland stacks are in
[FM](../porting/fm.md), [Wifi](../porting/wifi.md) and
[Bluetooth](../porting/bluetooth.md).

## Components

| Where | What |
| --- | --- |
| `daemon/native/src/radio.rs` | `Radio`: the `fm` op, the receiver's ioctls, the clocking carrier and the AFE route. |
| `daemon/native/src/output.rs` | `Routing`: the `output` op, the `pw-dump --monitor` cache, Bluetooth sink selection. |
| `daemon/lib/src/services/radio_host.dart` | `RadioHost`: validates a `POST /api/v1/radios` command, serializes it, resolves names to host state. |
| `daemon/lib/src/services/host_radios.dart` | `HostRadios`: the `wpa_cli`, `networkctl`, `bluetoothctl` and `busctl` sequences, and the child environment. |
| `packages/daemon_client/lib/src/radio_backend.dart` | `RadioBackend`, `WifiReading`, `BluetoothReading`, `WifiNetwork`, `BluetoothDevice`: the shape both the host and the emulator's mock fill. |
| `daemon/lib/src/services/bluetooth_player.dart` | `BluetoothPlayer`: the MPRIS object BlueZ exposes over AVRCP. |
| `daemon/lib/src/services/remote_player.dart` | `RemotePlayer`: the playback owner proxy the adapter commands and observes. |
| `daemon/systemd/tempod.service` | Starts the Dart daemon with `--radios --bluetooth-player`. |

## FM control

`Radio` in `radio.rs` is one value in the broker's `State`, holding a mutex
around `Inner`: the optional `Active` receiver and the last frequency, which
starts at 95.5 MHz. Every `fm` request takes that lock, so tuning, seeking
and status polls from different connections cannot interleave.

`apply` sequences a request in a fixed order. `frequency_khz` and `seek`
together are an error. `on: false` disables and returns. Otherwise the
frequency is validated to 87500 through 108000 in multiples of 100 and the
seek direction to -1 or 1 before anything touches the device. Then:

| Condition | Action |
| --- | --- |
| `on: true` and the receiver is off | `enable` at the requested frequency, else the last one. |
| Receiver already on and `frequency_khz` given | `tune`. An off receiver answers `radio is off`. |
| `seek` given | `seek` from the current frequency, after any tune. |
| Always | `status`, which refreshes RSSI and stereo and drains one RDS record. |

`enable` opens `/dev/fm` read-write, switches the antenna to the long
antenna, powers up with band, 100 kHz spacing and the channel number, starts
the carrier, sets the route, and turns RDS on. A carrier failure powers the
tuner down; a route failure stops the carrier and powers down; an RDS
failure is only a log line. After 60 ms it reads the signal and logs the
frequency and RSSI. `disable` is the reverse: route off, carrier stopped,
power down, collecting rather than stopping at errors, and remembering the
frequency for the next `on`. Dropping `Radio` runs the same teardown, so a
broker exit never leaves the tuner powered.

The carrier is a silent 48 kHz stereo stream on the sound server's
`default` device. The receiver is a 32 kHz I2S master into the AFE, and its
audio never enters PipeWire; the stream exists to keep the DAC clocked while
the `FM Playback Switch` mixer control on `hw:y2cs43131` connects the direct
path. Opening the hardware PCM directly would compete with the PipeWire
owner the wheel sounds already installed.

Tune and seek use the legacy vendor structures with no userspace pointers,
which is what makes them stable across the 32-bit ioctl boundary; the
request numbers are encoded with a pointer-sized payload because the vendor
header declared them that way. Both clear the decoded station, wait 60 ms,
then re-read the signal. A seek result outside the band is an error. The
`status` reply is the receiver's state plus whatever RDS has decoded:

```json
{"ok":true,"available":true,"on":true,"frequency_khz":95500,
 "rssi":-61,"stereo":true,"program_name":"...","radio_text":"...",
 "pi":1234,"pty":10}
```

`available` is whether `/dev/fm` exists. RDS reads are non-blocking; a zero
length read means nothing new. The program name comes from the PS block,
radio text from up to 64 bytes of the RT block, and bytes outside printable
ASCII and Latin-1 become spaces. The player's `DeviceFmRadio` polls this
op once a second while a screen listens.

## Host radio operations

`--radios` gives `PlayerServer` a `RadioHost`, which answers
`POST /api/v1/radios` with the bearer token and an `application/json` body.
Without the flag the route answers 503 `radio_unavailable`. A malformed
command is 400 `invalid_request` and a `RadioFailure` is 409 `radio_failed`
with the failure's message. The emulator never enables the flag; it fills
the same `RadioBackend` shape from mock state.

`RadioHost.execute` rejects a second command while one is running, then
validates the body before any process starts. Each operation allows exactly
its own fields:

| `operation` | Fields | Limits |
| --- | --- | --- |
| `refresh` | `scan` | boolean, default false |
| `wifi.enable`, `bluetooth.enable` | `enabled` | boolean |
| `wifi.join` | `ssid`, `password` | 32 and 63 characters, no NUL |
| `wifi.forget` | `ssid` | |
| `wifi.disconnect` | | |
| `bluetooth.connect`, `bluetooth.disconnect`, `bluetooth.forget` | `address` | `XX:XX:XX:XX:XX:XX` |

A `refresh` runs `backend.refresh(scan:)`. Every other operation first
refreshes without scanning, resolves the SSID or address against the
networks and devices just observed, failing with `Network is no longer
available` or `Device is no longer available`, runs the operation, and
refreshes again. The reply is always the full state: `wifi` with `status`,
`network` and `bars`; `bluetooth` with `status` and `device`; the
`networks` and `devices` lists; and `wifiError` and `bluetoothError`, which
carry a message when that radio's refresh failed. WiFi and Bluetooth
refresh in parallel so a missing service on one never hides the other.

`HostRadios` runs every tool through `runRadioCommand`: argument vectors,
`includeParentEnvironment: false`, `LC_ALL=C`, `TERM=dumb`, and a copy of the
parent environment with `NOTIFY_SOCKET`, `WATCHDOG_PID`, `WATCHDOG_USEC`,
`LISTEN_PID`, `LISTEN_FDS` and `LISTEN_FDNAMES` removed. That last part is
why `bluetoothctl` exiting cannot send `sd_notify` on the daemon's behalf
and stop `tempod.service`. Commands are killed after forty seconds, ANSI
escapes are stripped, and a non-zero exit or an output line starting with
`FAIL`, `Failed`, `Error`, `No default controller` or `Not available` is a
`RadioFailure`. Passwords go through stdin, never argv, and never appear in
an error.

The WiFi interface is `TEMPO_WIFI_INTERFACE` when set, else the first entry
under `/sys/class/net` with a `wireless` directory. Every `networkctl`
change first checks that systemd-networkd manages the interface.

| Operation | Sequence |
| --- | --- |
| `refresh` | `wpa_cli status`; with `scan` and the interface enabled, `wpa_cli scan` then three seconds; `scan_results` and `list_networks`, merged by SSID keeping the strongest signal, saved networks added even when not in range, connected first then by bars. |
| `wifi.enable` | `networkctl up` or `down`, then `wpa_cli reconnect` when enabling. |
| `wifi.join` | Refuse EAP, WEP and SAE-only networks. Reuse the saved network ID or `add_network` and set the SSID as hex and the PSK through stdin, or `key_mgmt NONE`. `networkctl up`, `select_network`, poll `status` once a second for fifteen seconds until `COMPLETED` on that ID, removing a newly created network on failure. Then `networkctl renew` and `save_config`. |
| `wifi.disconnect` | `wpa_cli disconnect`. |
| `wifi.forget` | `remove_network` and `save_config` when the network has an ID. |
| `bluetooth.enable` | `bluetoothctl power on` or `off`. |
| `bluetooth.connect` | `bluetoothctl --agent NoInputNoOutput pair` when not yet paired, then `busctl call org.bluez ... ConnectProfile` with the A2DP sink UUID. |
| `bluetooth.disconnect`, `bluetooth.forget` | `bluetoothctl disconnect` or `remove`. |

A Bluetooth refresh reads `bluetoothctl show` for the controller and its
powered state. A scan runs an interactive `bluetoothctl` session for five
seconds with `transport bredr` and the A2DP sink UUID filter, because a
one-shot `scan on` drops its filter when that client exits. `devices` and
`info` per device follow, keeping only devices that advertise the A2DP sink
UUID. A failed save reports that the change is active for the session but
not persisted.

## Bluetooth playback adapter

`--bluetooth-player` constructs `BluetoothPlayer` around the `RemotePlayer`
and starts it before the HTTP server. It is a `DBusObject` at
`/org/tempo/player` on the system bus implementing
`org.mpris.MediaPlayer2.Player`. Its properties are computed from the
owner's current `PlayerSnapshot`: `Identity` is `Tempo`, `PlaybackStatus`
is `Playing`, `Paused` or `Stopped` and is `Stopped` whenever the owner is
unavailable, `Metadata` carries `xesam:title`, `xesam:artist`,
`xesam:album` and `mpris:length` in microseconds, `Position` likewise,
`CanControl` follows availability, `CanPlay`, `CanPause` and
`CanGoPrevious` need a loaded track, `CanGoNext` follows `hasNext`, and
`CanSeek` is false.

`start` registers the object, then calls `org.bluez.Media1.RegisterPlayer`
on `/org/bluez/hci0` with those properties. Registration retries every three
seconds until it succeeds, is redone when `org.bluez` changes owner, and
never disturbs local playback when it fails. On every snapshot change the
adapter diffs the properties, ignoring `Position`, and emits
`PropertiesChanged` for the rest.

The peer's `Play`, `Pause`, `PlayPause`, `Stop`, `Next` and `Previous`
arrive as method calls with no arguments and become the player commands
`play`, `pause`, `toggle`, `stop`, `next` and `previous` on the same
serialized owner the HTTP API uses. `Play` and `Pause` are explicit, so a
repeated `Pause` from a peer cannot toggle playback back on. A
`PlayerFailure` is returned as `org.mpris.MediaPlayer2.Player.Error.Failed`.

Readiness is the adapter's other job. Some receivers restore their own
volume about a second after AVRCP reports `Playing`, and a Tempo volume
change sent during that window is overwritten. So when the published status
becomes `Playing`, or a registration finds it already playing, the adapter
waits `readyDelay`, 1.5 seconds, and then calls `onPlaybackReady(true)` if
the same playback epoch is still current, the object is still registered,
and the owner is still playing. Any status change, a BlueZ restart, or
`dispose` bumps the epoch and reports not ready at once.
`RemotePlayer.notifyBluetoothPlaybackReady` forwards that as a
`bluetoothPlaybackReady` notification on the owner connection, which is
what lets the player's volume service flush an adjustment it deferred.

Selecting the Bluetooth sink as the output is not part of this adapter. The
broker's `output` op, in `output.rs`, keeps a `pw-dump --monitor` stream
cached, lists the `bluez5` sinks it sees, and on `target` sets
`default.configured.audio.sink` with `pw-metadata`; the `volume` op reads
`device` and `hardware` from that same cache so the player knows when the
peer has hardware volume. The player side of that decision is described in
[Bluetooth](../porting/bluetooth.md).
