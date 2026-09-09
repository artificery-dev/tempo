# Tempo daemon: production services and development

The Dart host serves the player REST and WebSocket API through Relic. The
production native control broker runs in a separate Rust process and is
accessed through its existing Unix API. The versioned C ABI is diagnostic-only.
`packages/player_api` defines player commands, snapshots, and the service
interface without Flutter, Relic, or native dependencies.

Production uses `tempod.service` for the Dart API/services host and
`tempod-native.service` for the Rust hardware broker and persistent metrics
sampler. `tempod.socket` activates the native service. Rootfs staging and the
shared deployment tool install and enable this pair; it has been deployed and
validated on the Y2.

Dart owns authenticated media-library access and scan scheduling, settings,
Wi-Fi/Bluetooth host operations, AVRCP, and periodic battery/card observations.
Flutter remains the authoritative music playback owner and renders the UI.
Until it connects, playback reports `available: false` and commands return 503.
`--demo-player` explicitly enables an in-memory track for development; it does
not play audio. Persistent metrics collection remains in the native process.

## Run

Build a host bundle from the workspace root, then run the state-only demo:

```sh
toolbox dev daemon build --target host
export TEMPOD_API_TOKEN="$(openssl rand -hex 32)"
build/os/daemon/host/bundle/bin/tempod --demo-player --port 8765
```

The default listen address is `127.0.0.1`. Use `--bind` for a specific interface,
`--tls-cert` and `--tls-key` for HTTPS/WSS, or `--token-file` to load a token from
a local file. Tokens are never accepted in URLs. `--help` lists all options.

```sh
curl -H "Authorization: Bearer $TEMPOD_API_TOKEN" \
  http://127.0.0.1:8765/api/v1/player
curl -H "Authorization: Bearer $TEMPOD_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"type":"play"}' http://127.0.0.1:8765/api/v1/commands
```

The controller routes are:

| Route | Purpose |
| --- | --- |
| `GET /api/v1/device` | Latest battery and mounted-card observations |
| `GET /api/v1/player` | Current full player snapshot |
| `POST /api/v1/commands` | Validated command; response contains the resulting `state` |
| `GET /api/v1/events` | WebSocket upgrade, followed by full state snapshots |
| `POST /api/v1/media` | Cadence library and scheduler envelopes |
| `GET`, `PUT /api/v1/settings` | Persistent settings object |
| `POST /api/v1/radios` | Typed Wi-Fi/Bluetooth host operations |

Commands are `play`, `pause`, `stop`, `toggle`, `next`, `previous`, `seek` with
`positionMs`, and `setVolume` with `volume` from 0 to 1. Extra fields and invalid
values are rejected. The demo backend reports `unsupported_command` for
next/previous because it has one track. Real services implement their own
playback policy through `PlayerService`.

Errors use `{"error":{"code":"...","message":"..."}}`. Responses are
non-cacheable. HTTP commands require JSON, have a 64 KiB body limit and a
five-second body-read deadline. Authentication is checked before reading bodies
or upgrading WebSockets. Unknown service exceptions become a generic 500.

## Event protocol

Native clients connect with the same `Authorization: Bearer ...` header. The
first message is always a full snapshot:

```json
{"type":"snapshot","state":{"revision":0,"available":false,"status":"stopped","trackId":null,"title":null,"positionMs":0,"durationMs":0,"volume":1.0}}
```

Acknowledge each snapshot using `{"type":"ack","revision":0}`. Each
connection has at most one outstanding snapshot and one pending replacement.
Intermediate snapshots are coalesced until the acknowledgement arrives, so a
slow client receives the latest state without an unbounded application queue.
These are state snapshots, not a durable playback-history event log.

An acknowledgement must arrive within 15 seconds. Reconnect to obtain a fresh
snapshot; revision numbers are scoped to the current service session and are
not durable replay cursors. At most 16 subscribers are admitted. Closing the
server closes event connections and disposes their subscriptions.

Application close codes: 4001 shutdown, 4002 malformed messages, 4003 unavailable,
4004 service stream failure, 4008 acknowledgement timeout, 4009 oversized
message. Keepalive pings run every 10 seconds. Incoming JSON is checked after
Relic assembles the WebSocket message; a transport-level fragmented-message
size limit is not exposed by this adapter yet.

Browser origins are denied unless explicitly allowed with `--allow-origin`.
This is an origin gate, not a browser login or CORS implementation. Browser
JavaScript cannot set a WebSocket Authorization header: browser sessions and
CORS must be added before a web UI can use this API. Native Flutter/CLI clients
can use the header today.

## Native broker and diagnostic ABI

Production Dart calls `/run/tempod/tempod.sock`; it does not load the native
library. `tempod-native.service` owns the socket-activated Rust broker, its
subprocesses, metrics sampler and hardware resources. The Unix protocol retains
SCM_RIGHTS descriptor reception, peer credentials and DRM handoff. A matching
`LISTEN_PID` and single `LISTEN_FDS` entry transfer fd 3 to that process;
otherwise it binds the supplied path and refuses to replace a live socket.

For a local broker without metrics or real hardware requests:

```sh
cargo build -p tempod --bin tempod
build/rust/debug/tempod --no-sampler --socket /tmp/tempo-dev.sock
```

Point the Dart host's `--socket` at that path. Host radio/AVRCP services are
opt-in, and the emulator uses mocked data sources rather than a host broker.

`native/tempod_native.h` documents the diagnostic C ABI and handle/descriptor
ownership. `--native-library` remains available for isolated diagnostic tests,
**not production or any Dart process that also starts subprocesses**: Dart's
Linux child reaper can consume Rust subprocess exit statuses. See
[Native child-process boundary](#native-child-process-boundary).

FFI shutdown runs on a worker isolate, stops new requests and joins active
request handlers. Native handoff-completion threads finish independently. The
PipeWire routing monitor is owned by the native runtime: dropping it stops and
reaps `pw-dump`, interrupts retries and joins its reader thread. The diagnostic
shared library itself remains loaded for the Dart process lifetime.

## Build and verify

```sh
toolbox dev daemon build --target host
toolbox dev daemon build --target arm
```

Artifacts go to `build/os/daemon/{host,arm}/bundle`: `bin/tempod`,
`bin/tempod-native`, `lib/libtempod_native.so` (diagnostic ABI), SQLite's native
asset, and a checksummed manifest.
Keep the bundle's `bin/` and `lib/` layout intact. The standalone daemon compiler
is pinned to Dart 3.13.2 (the separately discovered Flutter 3.47.2 toolchain, or
`TEMPO_DAEMON_DART`). This does not change the device app's Flutter/engine pin.

The daemon uses `dart build cli` because SQLite requires a native-asset hook;
[`dart compile` does not support packages with build hooks](https://dart.dev/tools/dart-compile).
The build verifies that the ARM target is actually an ARM32 ELF executable.
`--dart-only` omits the private Rust core for runtime experiments.

ARM32 Dart 3.13.2 plus bundled SQLite have been run under QEMU with the recovery
sysroot: authenticated HTTP library creation and graceful SIGTERM shutdown
both pass. The production process pair also passed device deployment, clean service
restart and sustained playback checks.

```sh
toolbox dev daemon test
toolbox dev daemon check
```

The shared Dart developer tooling builds an isolated host runtime/native-asset
map and runs the daemon tests without changing the device app's
pinned Flutter dependencies. HTTP tests use loopback connections for commands,
authentication, malformed inputs, owner/event WebSockets, flow control and
cleanup. Native tests use temporary Unix sockets and fixtures for FD passing,
monitor shutdown, hardware protocols and process ownership; they need no device.
To include shared contract tests, use
`toolbox dev daemon test test ../packages/player_api/test`.
For native-only checks, use `cargo test -p tempod` and
`cargo clippy -p tempod --all-targets -- -D warnings`.

## Flutter playback owner and device observations

The app now lives at `app/`, with shared UI at `packages/tempo_core/`.
`packages/daemon_client/` contains the pure-Dart native control client, owner
connection, and device observation client; `player_api` stays independent of
transport code. Each new public class has its own file.

Run the daemon with two different credentials: `TEMPOD_API_TOKEN` for remote
controllers/device observations and `TEMPOD_OWNER_TOKEN` for the local Flutter
playback owner. `--owner-token-file` is the daemon's file alternative. Omit
`--demo-player` when connecting the real app. The owner endpoint is disabled
without an owner credential. Give the app these variables:

```text
TEMPOD_API_URL=http://127.0.0.1:8765
TEMPOD_API_TOKEN=<controller credential>
TEMPOD_OWNER_TOKEN=<separate owner credential>
```

The app also accepts `TEMPOD_API_TOKEN_FILE` and `TEMPOD_OWNER_TOKEN_FILE`.
Rootfs staging and daemon deployment generate these service settings. First
boot creates separate random credentials with restricted file permissions; no
shared credential is embedded in the image. The deployed pair uses these credentials; service and playback acceptance is
recorded in the diagnostic reports.

`GET /api/v1/owner` upgrades to an authenticated, single-owner WebSocket.
The Flutter owner sends `PlayerSnapshotEmitted` initially. The daemon requests
a fresh snapshot every second using `PlayerSyncRequested`, with at most one
outstanding sync and a five-second response deadline. This bounds unsolicited
state traffic without a second playback engine. Commands use the shared
request/success/failure events and correlation IDs. A separate owner token is
required even if a client already has the controller credential.

The daemon proxy publishes monotonically increasing revisions across owner
reconnects within its own lifetime. The app's session ID and source revisions
are separate. Lost connections publish unavailable state and fail pending
commands. The app reconnects automatically without replaying commands. A command
has a ten-second result deadline; an unknown outcome keeps the command slot
occupied until the owner replies or disconnects. Concurrent requests get
`player_busy`. Local UI and remote mutations use the same serialized Flutter
playback wrapper and queue.

This adapter covers the existing music player. Music controls report unavailable
while video or FM is active. Loading a library selection remains a local UI
operation; remote controllers can manipulate an already-loaded music queue.
The existing missing-libmpv fallback simulates silent playback; it is not proof
of working audio. Production audio/video acceptance uses real receiver capture.

`DeviceMonitor` owns five-second observations: battery through the native Unix
control service, and mounted-card discovery through `/proc/mounts`. It decodes
mount escapes and publishes unknown state when a source disappears. The app
polls the authenticated cached `/api/v1/device` snapshot every five seconds and
adapts it to Flutter listenables. It does not read sysfs or `/proc/mounts` as a
fallback. These cached observations are separate from persistent SQLite metrics
collection, which remains enabled in the native broker.

Flutter renders library queries from the daemon and retains applet/wallpaper
persistence and media/video engines. Settings persistence and host radio
subprocesses now belong to the daemon. Native DRM/FD
handoff, screen, mixer, FM hardware, haptic, sound, and timezone operations retain
their existing native control transport.

The integrated Bluetooth AVRCP adapter publishes the same serialized playback
owner used by local UI and daemon requests. Bluetooth Play/Pause use explicit
state commands, so repeated queued Pause requests cannot toggle back to Playing.
Paused hardware-volume changes retain the upstream UI deferral policy; API
commands that cannot confirm a change return an error instead of a false success.

### Daemon-owned media library

Pass `--media-database /home/tempo/.tempo/library.db` to host the existing
Cadence database and low-priority scanner in tempod. The device UI uses
authenticated `/api/v1/media` envelopes through `daemon_client`, preserving
Cadence library, roots, scan, artwork and settings operations. Closing a UI
client does not stop the library service. The daemon closes it on shutdown.
The media endpoint returns 503 when the service was not enabled.

The daemon owns startup scans (8 seconds for an empty library, 25 seconds for
an existing library) and card scans after a 3-second mount-settling delay. It
reuses DeviceMonitor observations and retains roots for absent cards. Saved
`/settings/library/roots`, `scan-on-boot`, `scan-on-card`, and `recheck` values
come from SettingsHost before timers start; successful settings writes update
the policy. Explicit folder removal releases scanner roots without erasing
indexed media. Manual scans remain available even with automatic scans disabled.

The `/scheduler` media envelope accepts GET for cached status and POST for a
manual scan across the six libraries. The daemon completes accepted work when
a UI disconnects. Device UIs only observe this status every two seconds and
refresh shelves when its epoch/revision changes, including after reconnecting.
Status reads do not walk directories or query every track. The offline emulator
continues to use local MediaLibrary startup/card scheduling.

Use `toolbox dev daemon test` (or `toolbox dev daemon test`) for tests. Shared tooling
builds the Rust test library and a host Dart bundle with SQLite, then runs tests
with an isolated package configuration/native-asset map under
`build/os/daemon/test-runtime`. This uses the daemon SDK without resolving or
changing the app's pinned Flutter dependencies. `toolbox dev daemon build --target arm` packages
the production ARM bundle; rootfs and deploy enable its media database/settings.

### Persistent player settings

`--settings-file` or `TEMPOD_SETTINGS_FILE` selects the existing user settings
JSON file. Authenticated `GET`/`PUT /api/v1/settings` reads and replaces the
settings object. The daemon serializes writes, flushes a temporary file before
renaming it, and drains accepted writes at shutdown. The device UI uses this
service; the emulator retains its local settings file. Corrupt saved content
is reported rather than silently replaced during loading. The endpoint is
unavailable when no settings file was configured.

## Host radio operations

`--radios` enables authenticated typed commands at `POST /api/v1/radios`.
The daemon owns Wi-Fi/Bluetooth polling and subprocess execution; Flutter uses
`daemon_client` adapters and no longer launches those commands on its UI
isolate. The endpoint is not an arbitrary shell interface. The emulator uses
mock radio state and never connects to host D-Bus or system networking.

Production readiness uses direct `sd_notify` with `NotifyAccess=main`.
Radio subprocess environments exclude systemd notification/watchdog/socket
activation variables, preventing child `bluetoothctl` shutdown notifications
from stopping the Dart service.

## Bluetooth playback adapter

`--bluetooth-player` enables the daemon-owned BlueZ AVRCP/MPRIS player. It
uses the same `RemotePlayer` and serialized Flutter playback owner as REST;
the emulator does not enable this option or connect to D-Bus. Snapshots carry
optional `artist`, `album` and `hasNext` fields, with null/false defaults for
older senders. Play, Pause and Stop are explicit operations, not toggles.

The private authenticated owner connection also carries
`bluetoothPlaybackReady` notifications. After BlueZ advertises Playing, the
daemon waits 1.5 seconds for the peer's volume restoration before permitting
DeviceVolume to flush a deferred Bluetooth adjustment. The notification carries
the latest owner revision; the owner rejects readiness predating a local
playback transition, and immediately gates adjustments on pause, new resume
or disconnect. Owner and BlueZ reconnections republish current state and
repeat the settling delay. This notification is not a public player command.

Host tests use an isolated D-Bus server and exercise registration, metadata,
commands, BlueZ/owner reconnect and stale readiness cancellation. The final Titan receiver test verified metadata, explicit Play/Pause/Stop and
paused-volume deferral/settled flush on the deployed pair. This does not establish
compatibility with every Bluetooth receiver.

## Native child-process boundary

Do not deploy `--native-library` alongside Dart subprocess operations. Dart's
Linux process reaper waits for any child and can consume Rust child statuses,
causing `No child processes (os error 10)` in wpctl and Plymouth operations.
The native broker must have a separate process parent for those commands;
Dart continues to call its existing Unix API. The diagnostic C ABI remains
available for isolated tests, not production mixed-subprocess hosting.

Run the host-only regression with a built native executable:

```sh
TEMPOD_TEST_NATIVE_EXECUTABLE=/absolute/path/to/tempod \
  toolbox dev daemon test
```

It supplies private wpctl/pw-dump fixtures and checks 40 successful native
volume operations while Dart's child reaper is active. No hardware or actual
sound-server commands are used.
