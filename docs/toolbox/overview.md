# Toolbox overview

Toolbox is the host side of Tempo: the installer that backs up, restores and
flashes a Y2 over USB, the host for the mocked player emulator, and a small set
of tools for a running player. It ships in three presentations that share one
operation policy: a Flutter desktop and mobile application, a standalone
`toolbox` command line, and a browser build. Every storage decision is made in
the Rust `tempo-usb` engine, which the native builds run as a helper process
and the browser build runs as WebAssembly. The Dart layers choose files,
render progress and present the same options; they never issue a USB command
themselves.

## Components

| Where | What |
| --- | --- |
| `toolbox/app/lib/main.dart` | The GUI: the router, the Player page, the Backup & Restore walkthrough and its dialogs. |
| `toolbox/app/lib/toolbox_controller.dart` | `ToolboxController`: operation state that survives navigation, driven by engine events. |
| `toolbox/app/lib/toolbox_ui.dart` | `ToolboxSection`, the shell with sidebar or bottom navigation, headers and info rows. |
| `toolbox/app/lib/engine.dart`, `engine_native.dart`, `engine_web.dart` | `UsbEngine`: the native file choosers and helper calls, or the browser sessions. |
| `toolbox/app/lib/live_device*.dart`, `native_advanced*.dart` | The Live Player page and the native-only Advanced cards, with empty web stand-ins. |
| `toolbox/app/lib/emulator/` | The emulator host; see [Emulator](emulator.md). |
| `toolbox/app/web/` | `index.html`, `installer.js` and the web app manifest. |
| `toolbox/app/.fvmrc` | Toolbox's own Flutter pin. |
| `toolbox/cli/bin/toolbox.dart`, `lib/command_help.dart` | The command line and its per-command help. |
| `toolbox/tool/*.dart` | `analyze`, `build`, `check`, `device`, `dist`, `format`, `get` and `test` wrappers that forward to `toolbox dev`. |
| `toolbox/linux/70-tempo-recovery.rules` | The udev rule bundled beside the Linux executables. |
| `packages/toolbox_core/lib/toolbox_core.dart` | `ToolboxOperations`: the shared end-user operation policy; see [Device operations](device-operations.md). |
| `packages/toolbox_core/lib/live_device.dart`, `support_diagnostics.dart` | SSH transport, checked writes on a running player and the read-only support report. |
| `packages/tempo_usb/lib/src/native_engine.dart` | `NativeUsbEngine`: one helper process per operation. |
| `packages/tempo_usb/lib/src/engine_web.dart`, `browser/` | The browser engine, WebUSB and Web Serial sessions, staging and gzip streaming. |
| `packages/tempo_usb/rust/` | The `tempo-installer` crate: the `tempo-usb` binary and the Wasm library; see [USB engine](usb-engine.md). |
| `packages/tempo_build/lib/src/toolbox.dart`, `toolbox_linux.dart` | `toolbox dev toolbox build` and `check`, and the Linux container builder. |
| `build/toolbox/` | Build products: `rust/`, `cli/`, `flutter/` and the container SDK under `linux-sdk/`. |

## The GUI

The application is titled Tempo Toolbox and is built on `tomeui`. Its
navigation is `ToolboxSection`: Player, Device Settings, Emulator and Backup &
Restore, shown as a sidebar at 850 pixels and wider and as a bottom bar below
that. The router maps each section to `/<name>`, redirects `/flash` to
`/backup`, hides `/emulator` when the emulator is unavailable, and adds
`/live-player`. The Device Settings page is a placeholder that marks its
content `[NYI]`, as do the example serial, firmware, storage and health figures
on the Player page until device reporting exists; the chip field switches to
the probed hardware code once a connection check has run.

The Player page carries three header actions: Check USB connection, which runs
a probe with no task selected; Live Player on desktop builds; and Connection
help, a dialog whose steps differ between the native listener and the browser
picker. Backup & Restore is a five-step walkthrough: choose the operation,
choose the source or destination, options, review, and connect and transfer.
Below the three operation cards, native builds offer Other, which opens the
read-only diagnostics of the Advanced card. Sections other than the one running
an operation are disabled while the engine is busy, except Emulator and
Settings.

The Live Player page connects to a running player over `ssh` at a host and
account, `10.42.0.1` and `tempo` by default, and offers Check connection,
Collect support report, Save report and Choose app bundle. Deployment validates
a built Flutter bundle locally, runs a dry run against the player, shows a
review dialog, and only then replaces `/opt/tempo/flutter_assets`; see
[Working with a device](../development/device.md).

## The command line

`toolbox [--json] <command>` compiles from `toolbox/cli/bin/toolbox.dart`.
Progress goes to stderr; with `--json` every event is one JSON line and the
final result is the last line on stdout. Interrupting with SIGINT cancels the
running operation.

| Command | What it does |
| --- | --- |
| `device list`, `device info` | Discover a player in MediaTek boot mode, waiting 1 or 30 seconds. |
| `partitions` | Read the vendor partition map and report which address convention the chip uses. |
| `fetch NAME OUTPUT` | Read one vendor partition, `boot1` or `boot2`, into a new file. |
| `backup OUTPUT.gz [--resume DIRECTORY]` | Back up the eMMC as one gzip image. |
| `restore INPUT --yes [--resume] [--allow-preloader]` | Restore a gzip backup or a legacy backup directory. |
| `install FILE --yes [--resume] [--allow-preloader]` | Validate and install a `.y2-firmware` package. |
| `inspect FILE` | Validate a package without a device. |
| `inspect-raw BOOTIMG\|LOGO\|BOOT1 FILE` | Check a raw image header, size and checksum. |
| `install-raw NAME FILE SAFETY --dry-run\|--yes` | The guarded BOOTIMG and LOGO path, currently dry-run only. |
| `doctor` | Report whether `tempo-usb` and `DA.img` were found. |
| `diagnose [--host] [--user]`, `diagnose --usb` | The SSH support report, or a boot-mode probe. |
| `dev …` | The developer commands of `tempo_build`; see [The `toolbox dev` command reference](../development/toolbox-dev.md). |

`--loader DA.img` replaces the bundled download agent and `--preloader FILE`
supplies a preloader for BROM memory setup only. Exit codes are 0 for
success, 1 for an engine error, 64 for a usage error, 69 when `doctor` finds a
resource missing, and 130 when cancelled. Every write command requires `--yes`,
and preloader writes additionally require `--allow-preloader`.

## The browser build

The web build serves the same Flutter application with `packages/tempo_usb`'s
browser engine. `installer.js` imports the wasm-bindgen module from
`pkg/tempo_installer.js`, exposes its readiness as `window.tempoUsbWasmReady`,
then loads `flutter_bootstrap.js`; `DA.img` is fetched from the site root at
startup. The engine refuses Firefox and any context that is not secure, so the
page works in a desktop Chromium browser over HTTPS or on `localhost`. When
WebUSB is missing the app shows a page pointing at the native download. The
Advanced card adds Connect via serial, which uses Web Serial when the browser
provides it.

Browser transfers use the Legacy Download Agent only; selecting a Tempo
Recovery transfer raises an error that names the Advanced switch. Restore,
backup resume and the raw-image path are unavailable. Firmware packages are
chosen through the file picker, must end in `.y2-firmware`, and are staged into
origin private file storage after the Dart ZIP reader has checked the archive
and Rust has validated the manifest. A backup is written to a temporary browser
file that downloads when complete if the storage quota has room for the whole
image plus 64 MiB; otherwise it needs `showSaveFilePicker` and streams to the
chosen file directly.

## The engine boundary

On desktop `NativeUsbEngine` starts one `tempo-usb` process per operation. The
helper writes JSON events to stdout and diagnostics to stderr, and the Dart
side treats `result`, `error`, `firmware-info` and `raw-image-info` as the
terminal event. Cancellation writes `cancel` to the helper's stdin so it can
finish its bounded transfer, then escalates to SIGTERM after thirty seconds and
SIGKILL two seconds later. The engine is found through `TEMPO_USB_ENGINE`, then
beside the running executable, then at `build/toolbox/rust/release/`; the agent
through `TEMPO_USB_AGENT`, then `DA.img` beside the engine, then
`platform/firmware/DA.img`. `ToolboxOperations` in `toolbox_core` turns each
GUI or CLI request into the helper's arguments, so both presentations enforce
the same policy; [Device operations](device-operations.md) describes it.

## Building

`toolbox dev toolbox build [target]` accepts `native`, `web`, `cli`, `linux`,
`macos`, `windows`, `apk` and `ios`; `native` means the host platform and is
the default. `--gui-only` rebuilds a desktop GUI without recompiling the CLI.
Every target requires `platform/firmware/DA.img`; see
[Firmware inputs](../platform/firmware-inputs.md).

| Target | Steps |
| --- | --- |
| `web` | `cargo build` for `wasm32-unknown-unknown`, `wasm-bindgen` into `toolbox/app/web/pkg`, copy `DA.img` into `web/`, `flutter build web --no-web-resources-cdn`. |
| `cli`, desktop | Build Recovery, `cargo build --locked --release --bin tempo-usb`, `dart compile exe` to `build/toolbox/cli/toolbox`, copy resources, then `flutter build <platform>` and copy resources into the GUI bundle. |
| `apk`, `ios` | `flutter build` only; no helper is packaged. |

The resources copied beside each native executable are `tempo-usb`, `DA.img`,
`70-tempo-recovery.rules` and a `recovery/` directory holding
`ramboot-DA.bin`, `payload.bin` and `preloader.bin` from `build/recovery`; a
missing recovery file stops the build. File modes are normalised to 755 and
644. A desktop GUI can only be built on its own operating system; the CLI is
built first either way.

On Linux the whole build runs in the toolchain container.
`LinuxToolboxBuilder` stages the pinned SDK under `build/toolbox/linux-sdk/`,
copying a host SDK of that revision when one is found and otherwise cloning
Flutter at the pinned revision, gives it a private `HOME` and `PUB_CACHE` under
`build/toolbox/`, and points Flutter's build directory at
`build/toolbox/flutter` so host caches are never shared. Dependencies must be
resolved on the host first; package roots outside the checkout are mounted
read-only. On macOS and Windows the Rust helper is built with the host's cargo,
because the container cannot link a native USB executable for those systems.

`toolbox dev toolbox check` runs `cargo fmt --check`, `cargo test --locked`
and `cargo clippy` with warnings as errors, the browser tests in
`packages/tempo_usb/test` compiled for Node against a fresh Wasm build,
`flutter analyze` and `flutter test` in `toolbox/app`, and `dart analyze` and
`dart test` in `toolbox/cli`. See [Testing and checks](../development/testing.md).

## Platforms

The Flutter project carries `android`, `ios`, `linux`, `macos`, `windows` and
`web` runners. The emulator opens as a second native window on Linux, macOS and
Windows and as an in-app route on Android and iOS; the Live Player page and the
Advanced cards exist only in native desktop builds, and the CLI is a Dart
executable for the host it is compiled on. `toolbox/app/README.md` states that
Linux desktop builds and emulator startup have been tested, that an Android
emulator-mode debug APK builds, that macOS, Windows, Android and iOS runtime
execution has not been verified there, and that a native mobile USB helper
would still need platform transport integration. The mocked emulator needs no
USB access on any platform.

## The independent SDK pin

`toolbox/app/.fvmrc` pins Toolbox to a Flutter commit rather than to the
release number in the root `.fvmrc` and `flutter.sdk_version` in
`config.yaml`, which the device app shares with `flutter-pi` and its engine
binaries. `toolboxCommand` reads the Toolbox pin when the file exists and uses
it both for host SDK discovery and for the container SDK. The pin exists so
Toolbox can track Flutter's native windowing API, which `pubspec.yaml` enables
with `enable-windowing: true`, without moving the device pairing described in
[flutter-pi and engine pairing](../app/flutter-pi.md).
