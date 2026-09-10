# Player architecture

The player is one Flutter application split across a thin device binary and
a shared UI package. `app/` is the binary flutter-pi runs on the Y2: its
`main` mounts the UI on the panel, and its `DaemonApp` wires the UI to
`tempod` and `cadenced`. Every screen, widget and service interface lives in
`packages/tempo_core`, which the Toolbox emulator runs too, with services it
feeds by hand. Two pure-Dart packages sit under both: `player_api` is the
playback contract shared with the daemon, and `daemon_client` is the set of
transports the app uses to reach it. This page describes those layers and the
seam between them; the screens themselves are in [Interface](interface.md).

## Components

| Where | What |
| --- | --- |
| `app/lib/main.dart` | The device entry point: `PanelSurface` around `DaemonApp`, the video player registration and the splash hand-off. |
| `app/lib/src/daemon_app.dart` | `DaemonApp`: opens the daemon clients and Cadence, builds `PlayerServices.device`, and mounts `TempoApp`. |
| `app/lib/src/daemon_device_readings.dart` | `DaemonDeviceReadings`: battery and card readings as UI listenables over `DeviceClient`. |
| `app/lib/src/daemon_data_storage.dart` | `DaemonDataStorage`: the data storage controller over `StorageClient`, polled every two seconds. |
| `app/lib/src/daemon_card_maintenance.dart` | `DaemonCardMaintenance`: eject, resume and format through `/api/v1/storage/card`. |
| `app/lib/src/flutter_player_service.dart` | `FlutterPlayerService`: the app's `PlaybackService` exposed as a `player_api` `PlayerService`. |
| `app/pubspec.yaml`, `app/tool/*.dart` | Dependencies, and thin wrappers over `toolbox dev app build`, `deploy`, `attach` and `clean`. |
| `app/test/` | The app's own suites, including a daemon integration test. |
| `packages/tempo_core/lib/tempo_core.dart` | The package's exports: the app, dock, menu, screens, settings and services. |
| `packages/tempo_core/lib/src/services/services.dart` | `PlayerServices`, `PlayerServices.device` and `PlayerServicesScope`. |
| `packages/tempo_core/lib/src/services/device_services.dart`, `screen.dart` | The device implementations that talk to `tempod` over its control socket. |
| `packages/player_api/` | `PlayerService`, `PlayerCommand`, `PlayerSnapshot`, the event envelopes and `StorageStatus`. |
| `packages/daemon_client/` | `Tempod`, `DeviceClient`, `SettingsClient`, `StorageClient`, `MediaTransport`, `RadioClient` and `PlaybackOwnerConnection`. |
| `packages/flutter_pi_plymouth_handoff/` | The Dart half of the splash hand-off, one method channel call. |
| `packages/tempo_build/lib/src/app.dart` | The `toolbox dev app` commands. |

## Two binaries, one UI

`app/lib/main.dart` does four things. It registers
`flutterpi_gstreamer_video_player`, which is the video backend flutter-pi
provides. It sets `WallpaperSource.installDefault`, so a profile with no
wallpaper gets the bundled one written into it. It runs `PanelSurface` around
`DaemonApp`, so the UI is laid out for the panel described in
[Interface](interface.md). Finally it calls `PlymouthHandoff.armOnFirstFrame`,
which takes the panel over from the boot splash at the first frame; the
mechanism is in [Boot splash](../platform/splash.md). Under `FLUTTER_TEST` the
video registration and the wallpaper write are skipped and a bare `TempoApp`
is mounted instead.

The emulator in `toolbox/app` mounts the same `TempoApp` inside a
`PanelSurface` with a size, and hands it a `ClickWheelController` and a
`PlayerServices` built from its rig. Nothing in `tempo_core` knows which host
it is on; see [The emulator](../development/emulator.md).

`tempo_core` depends on `tomeui` for the widget toolkit and on
`tomeui_clickwheel` for the wheel grammar, both published packages, pinned at `^0.3.2` in `packages/tempo_core/pubspec.yaml`.
It also depends on `cadence_client`, on `cadence_media` for the emulator's
in-process library, and on `media_kit` for libmpv playback. `app` adds
`player_api`, `daemon_client`, `flutter_pi_plymouth_handoff` and the video
player plugin, and turns `uses-material-design` off.

## DaemonApp startup

`DaemonApp` opens everything in one `_open` sequence and shows a placeholder
until it is done. Its inputs are environment variables that `tempo.service`
supplies on the device:

| Variable | Default | Use |
| --- | --- | --- |
| `TEMPOD_API_URL` | `http://127.0.0.1:8765` | The daemon's HTTP API. |
| `TEMPOD_API_TOKEN`, or `TEMPOD_API_TOKEN_FILE` | empty | Bearer token for device, settings, storage and radio requests. |
| `TEMPOD_OWNER_TOKEN`, or `TEMPOD_OWNER_TOKEN_FILE` | empty | The playback owner credential; without it remote playback is off. |
| `CADENCE_SOCKET` | `/run/cadenced/media.sock` | The Cadence Unix socket. |

The sequence is:

1. `StorageClient.status()` reads the profile. `DaemonDataStorage` wraps it;
   if the profile is not available the app shows `DataStorageRecoveryApp`
   and stops here.
2. `Places` is rebuilt from the profile's `mediaHome` and `configPath`, over
   the local filesystem `DevicePlaces` already knows.
3. `DaemonDeviceReadings` starts a `DeviceClient` polling `/api/v1/device`
   every second.
4. `CadenceLibrary` connects over `UnixMediaTransport`. A failure is logged
   and tolerated: settings and wallpaper come from internal storage, and
   collection polling recovers later.
5. `DaemonCardMaintenance` is made with a callback that stops audio and video
   before any card operation.
6. `PlayerServices.device` is built with the profile's places, the daemon's
   settings read and write, the Cadence library and path resolver, and the
   daemon's battery and storage readings.
7. `FlutterPlayerService` wraps playback, volume and FM radio, and
   `PlaybackOwnerConnection` attaches it to `/api/v1/owner` over WebSocket
   when the owner token is present.

Card activity is reported back to the daemon through `setMediaBusy`. The card
counts as busy while Cadence is busy or unknown, a track is loaded, video is
active, or card maintenance is running or has failed. When the Cadence volume
leaves the `attached` state, or its identity changes, playback is stopped.

## PlayerServices

`PlayerServices` is an immutable record of everything the UI may know about
the machine. Widgets read it through `PlayerServicesScope.of(context)`, which
falls back to `PlayerServices.device()` when nothing is installed, so a screen
mounted bare still shows something true. Each field is an interface with a
device implementation and an emulator implementation:

| Field | Interface | Device | Emulator |
| --- | --- | --- | --- |
| `battery` | `ValueListenable<BatteryReading>` | `DaemonDeviceReadings.battery` | The rig's notifier |
| `wifi`, `bluetooth` | `ValueListenable<WifiReading>`, `ValueListenable<BluetoothReading>` | `RadioService` in `host` mode over `RadioClient` | `RadioService` in `mocked` mode |
| `storage` | `ValueListenable<StorageReading>` | `DaemonDeviceReadings.storage` | The rig's card |
| `places` | `ValueListenable<Places>` | `DevicePlaces` seeded from the profile | The rig's host folders |
| `screen` | `ScreenService` | `DeviceScreen`, the `screen` op on the `tempod` socket | `ScreenSwitch` |
| `volume` | `VolumeService` | `DeviceVolume` | `VolumeSwitch` |
| `output` | `OutputService` | `DeviceOutput` | `OutputSwitch` |
| `feedback` | `FeedbackService` | `DeviceFeedback` | `FeedbackSwitch` |
| `fmRadio` | `FmRadioService?` | `DeviceFmRadio` | `EmulatorFmRadio` over `FmRadioSwitch` |
| `timeZone` | `DeviceTimeZone?` | `DeviceTimeZone` | Absent |
| `applets` | `AppletStore` | `AppletStore` over the profile's places | `AppletStore` over the emulated home |
| `library` | `LibraryService` | `CadenceMediaLibrary` over `CadenceLibrary` | `MediaLibrary.open` over `cadence_media` |
| `playback` | `PlaybackService` | `CadencePlayback` over `SerializedPlayback(MediaKitPlayback)` | `SerializedPlayback(MediaKitPlayback)` |
| `dataStorage` | `DataStorageController?` | `DaemonDataStorage` | The rig's controller |
| `cardMaintenance` | `CardMaintenanceController?` | `DaemonCardMaintenance` | Absent |

`DeviceBattery` still exists in `device_services.dart` as the native
fallback over the `battery` op, but `DaemonApp` passes the daemon reading in
its place. `DeviceWifi`, `DeviceBluetooth` and `DeviceStorage` are constant
placeholders used only when no radio service or daemon reading is supplied.
Where libmpv is missing, `devicePlayback` falls back to `SilentPlayback` and
logs it. Under `FLUTTER_TEST` the library, playback, radios, FM radio and time
zone are left out, because the test host's home is nobody's to open.

`readSettings` and `writeSettings` are how the settings file reaches the
daemon. `TempoApp.open` installs the bindings, loads the file through
`SettingsFile.at` with those two callbacks, applies every value to the
machine, and only then starts watching for changes. The settings system is
described in [Settings system](settings.md).

## player_api

`player_api` depends on nothing but the Dart SDK. `PlayerService` is the
contract for the authoritative playback owner: a synchronous `snapshot`, a
broadcast `changes` stream, and `execute(PlayerCommand)`. Snapshots are
complete state with a revision that increases within one service session.
`PlayerCommand.fromJson` accepts one of `play`, `pause`, `stop`, `toggle`,
`next`, `previous`, `seek` with `positionMs`, and `setVolume` with a volume
from 0 to 1, and rejects anything else. `UnavailablePlayer` is the startup
state until a real owner connects. The package also carries the app to
daemon event envelopes, listed in `packages/player_api/README.md`, and
`StorageStatus`, the profile description the storage endpoint returns.

`FlutterPlayerService` is the app's implementation. It reports `available:
false` while video or FM radio is active, refuses a second command while one
is running with `player_busy`, refuses everything but `stop` and `setVolume`
with no track loaded, and routes `setVolume` through
`DeviceVolume.setLevelConfirmed` so the level is acknowledged before the
snapshot moves. Every listener change bumps the revision and emits a new
snapshot.

## daemon_client

`daemon_client` is also pure Dart. Each class owns its connection and must be
closed by its owner; nothing is retried after a disconnect.

| Class | Endpoint | Role |
| --- | --- | --- |
| `Tempod` | The `tempod` Unix socket | One JSON object per line, one reply, then the daemon hangs up. `screen`, `battery` and the DRM hand-off use it. |
| `DeviceClient` | `GET /api/v1/device` | Polled `DeviceSnapshot`: battery, charging, card path, mount and source IDs, I/O activity. |
| `SettingsClient` | `/api/v1/settings` | Read the whole map; a write is acknowledged once on disk. |
| `StorageClient` | `/api/v1/storage`, `/api/v1/storage/card` | Profile status and selection, and card maintenance. |
| `MediaTransport` | `POST /api/v1/media` | Authenticated envelopes for Cadence's transport-independent client. |
| `RadioClient` | `POST /api/v1/radios` | WiFi and Bluetooth commands; the hardware is touched only in the daemon. |
| `PlaybackOwnerConnection` | `GET /api/v1/owner` upgraded to WebSocket | Publishes a `PlayerService` as the owner and reconnects after loss. |
| `PlaybackReadinessGate` | none | Drops a late AVRCP readiness signal from an earlier playback transition. |

`tempo_core` re-exports `Tempod` and `TempodError` from
`services/tempod.dart`, so the device services take a `Tempod` without the
package importing `daemon_client` everywhere. The daemon side of these
endpoints is in [tempod](daemon.md).

## Building and deploying

`toolbox dev app` has four actions, and `app/tool/build.dart`, `deploy.dart`,
`attach.dart` and `clean.dart` forward to them.

| Action | What it does |
| --- | --- |
| `build [--release]` | `flutter pub get`, then `flutter build bundle` into `build/app/flutter_assets`. With `--release`, compiles `package:tempo/main.dart` to `tempo.aot.dill` with the SDK's `frontend_server_aot`, then runs the engine's `gen_snapshot` to produce `app.so` beside the assets. |
| `deploy [--release] [--dry-run]` | Ships the bundle to the device over the configured transport and restarts the player. |
| `attach [--dry-run]` | `flutter attach` to the debug build's VM service on the gadget address at `flutter.vm_service_port`. |
| `clean` | Removes the bundle and the AOT dill. |

A release build refuses to run when the SDK's `engine.version` differs from
the fetched engine's `flutter.version`, because the snapshot must come from
the same engine flutter-pi will load. That pairing, and the embedder build
itself, are in [flutter-pi and engine pairing](flutter-pi.md). The overall
build order is in [Building](../development/building.md), and deployment in
[Working with a device](../development/device.md).
