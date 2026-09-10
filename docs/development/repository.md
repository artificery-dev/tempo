# Repository layout

The Tempo checkout holds every component of the firmware and the tools that
build and install it: the Flutter player and its embedder, the `tempod`
daemon with its Rust core, Toolbox, the Debian root filesystem, the kernel
fork as a submodule, vendor firmware through Git LFS, and the `tempo_build`
package that turns all of it into `build/dist/`. The Dart side is one pub
workspace with a handful of independently resolved packages around it; the
Rust side is one Cargo workspace plus the standalone USB engine crate. Three
Flutter SDKs are pinned because three different things constrain them.

## Components

| Where | What |
| --- | --- |
| `app/` | The device Flutter app, the pinned flutter-pi submodule, its patches and plugins. |
| `daemon/` | `tempod`: the Dart service host, its systemd units, and the Rust hardware core under `daemon/native/`. |
| `packages/` | Shared Dart packages, the `tempo_kms` Rust crate and the `tempo_usb` USB engine. |
| `assets/` | The `tempo_assets` package: artwork shared by the app and Toolbox. |
| `toolbox/app/`, `toolbox/cli/` | Toolbox as a Flutter GUI and as the command-line tool that also hosts `toolbox dev`. |
| `toolbox/tool/`, `app/tool/`, `daemon/tool/`, `platform/*/tool/` | `dart run` entry points that forward to `toolbox dev` routes. |
| `platform/` | Kernel, rootfs, Bluetooth bootstrap, splash, recovery, firmware, diagnostics and the toolchain container. |
| `docs/` | This documentation. |
| `config.yaml`, `config.local.yaml` | Tracked configuration and the gitignored local overlay; see [Development setup](setup.md). |
| `pubspec.yaml` | The root pub workspace. |
| `Cargo.toml` | The root Cargo workspace. |
| `.gitmodules`, `.gitattributes` | The two submodules and the Git LFS patterns. |
| `build/` | Gitignored build output, with the final image set under `build/dist/`. |

## Components in detail

| Path | Purpose |
| --- | --- |
| `app/` | The `tempo` Flutter package that runs on the device under flutter-pi. |
| `app/flutter-pi/` | The `flutter-pi` submodule, `patches/`, the `plymouth_handoff.c` plugin, `toolchain-armhf.cmake` and the native handoff test. |
| `daemon/` | The `tempod` Dart package, `bin/tempod.dart`, and `systemd/` units installed by rootfs staging. |
| `daemon/native/` | The `tempod` crate: the `tempod` binary and `libtempod_native` library. |
| `packages/tempo_core/` | The player UI and service interfaces shared by the app and the emulator. |
| `packages/player_api/`, `packages/daemon_client/` | Player contracts, and the transports the app uses to reach the daemon. |
| `packages/tempo_data/` | Profiles and storage management. |
| `packages/tempo_logger/` | Logging on the device and on the host. |
| `packages/flutter_pi_plymouth_handoff/` | The Dart side of the plymouth to flutter-pi hand-off. |
| `packages/toolbox_core/` | Device operation policy, transports and firmware package handling shared by Toolbox's GUI and CLI. |
| `packages/tempo_usb/` | The USB engine: a Rust crate built natively as `tempo-usb` and as Wasm for the browser, with its Dart bindings and browser tests. |
| `packages/tempo_kms/` | The `tempo-kms` crate: KMS plumbing shared by the device tools. |
| `packages/tempo_build/` | Repository configuration, SDK discovery and every `toolbox dev` command. |
| `platform/kernel/` | The `linux` submodule and `config/y2.config`. |
| `platform/rootfs/` | The overlay, the initramfs template, and the `tempo-system` runtime source. |
| `platform/bluetooth/` | The modem bootstrap that brings up the radio hardware. |
| `platform/splash/` | The boot logo assets and plymouth theme. |
| `platform/recovery/` | Tempo Recovery: its init, transfer service, UI and build script. |
| `platform/firmware/` | Vendor binaries; see [Firmware inputs](../platform/firmware-inputs.md). |
| `platform/diagnostics/` | On-device probe sources and host analysis tools. |
| `platform/toolchain/` | The `Containerfile`. |

## The pub workspace

The root `pubspec.yaml` is the `tempo_workspace` package. Its `workspace:`
list names the members, each of which declares `resolution: workspace`, so
they share one dependency resolution and one `.dart_tool/` at the root:

| Member | Package |
| --- | --- |
| `app` | `tempo` |
| `assets` | `tempo_assets` |
| `daemon` | `tempod` |
| `packages/daemon_client` | `daemon_client` |
| `packages/flutter_pi_plymouth_handoff` | `flutter_pi_plymouth_handoff` |
| `packages/player_api` | `player_api` |
| `packages/tempo_core` | `tempo_core` |
| `packages/tempo_logger` | `tempo_logger` |

`tempo_build` is the workspace's single dev dependency, which is what lets
`dart run app/tool/build.dart` and the other `tool/*.dart` entry points find
the dispatcher. The Cadence client and media packages are Git dependencies of
`app`, `daemon` and `tempo_core` on the public repository at
`https://git.artificery.dev/artificery/cadence`, path `packages/client` and
`packages/media`; the daemon itself is not built here but fetched as a release
bundle, see [Building](building.md).

The packages outside the workspace resolve on their own: `toolbox/app`,
`toolbox/cli`, `packages/tempo_build`, `packages/toolbox_core`,
`packages/tempo_usb` and `packages/tempo_data`. They reach the shared packages
through path dependencies. `toolbox dev workspace get` runs `flutter pub get`
at the root and then in each of these, using each root's own SDK; `analyze`,
`test` and `format` walk the same set.

## The Cargo workspaces

The root `Cargo.toml` is a workspace with two members, `daemon/native` and
`packages/tempo_kms`. It sets `resolver = "3"` and `rust-version = "1.90"`
so the lockfile only picks dependency versions the container's toolchain can
build, and its release profile optimises for size with LTO, a single codegen
unit, stripping and `panic = "abort"`, since the outputs run from a small
root filesystem. `daemon build` sets `CARGO_TARGET_DIR` to `build/rust`, so
removing `build/` cleans the Rust output too.

`packages/tempo_usb/rust` is a separate workspace of one crate,
`tempo-installer`. It builds the `tempo-usb` helper natively for Toolbox and
a `cdylib` for `wasm32-unknown-unknown`, with `wasm-bindgen` pinned at
`=0.2.122` to match the `wasm-bindgen-cli` in the container. Its target
directory is `build/toolbox/rust`.

## Submodules and LFS

`.gitmodules` declares two shallow submodules:

| Submodule | Source | Notes |
| --- | --- | --- |
| `platform/kernel/linux` | `github.com/artificery-dev/linux`, branch `tempo/innioasis-y2` | The pin is the recorded commit; see [Kernel](../platform/kernel.md). |
| `app/flutter-pi/flutter-pi` | `github.com/ardera/flutter-pi` | `ignore = dirty`, because the build applies `app/flutter-pi/patches/` in place and copies the handoff plugin in. The checkout must match `flutter.flutter_pi.commit`. |

Bootstrap runs `git submodule update --init --recursive --depth 1`. Ordinary
builds never move either pin.

`.gitattributes` routes `platform/firmware/DA.img` and every `.bin` and
`.img` under `platform/firmware/stock/` through Git LFS. The scatter file and
the small partition tables stay ordinary blobs. Bootstrap pulls the LFS files
and refuses to continue while any of them is still a pointer.

## SDK pins and why they differ

| Pin | Where | Constraint |
| --- | --- | --- |
| `flutter.sdk_version` | `config.yaml` | flutter-pi loads a prebuilt `libflutter_engine.so` from `flutter.engine_binaries` at a fixed commit, and the AOT snapshot must come from that engine's `gen_snapshot`. `app build --release` compares the SDK's `engine.version` with the fetched engine's `flutter.version` and stops on a mismatch. |
| `daemon.toolchain_version` and `daemon.dart_version` | `config.yaml` | `tempod` is plain Dart with no engine, so it uses a newer compiler. The Flutter SDK is the delivery vehicle; the build checks the bundled Dart's reported version. |
| `flutter` | `toolbox/app/.fvmrc` | Toolbox is a desktop, web and mobile app on its own release cadence. `toolbox build` and `emulator run` read this pin. |

The pinned versions and how they are provisioned are in
[Toolchain container](../platform/toolchain.md). The container carries its
own Rust toolchain and a standalone Dart SDK for the browser tests; neither
replaces a Flutter pin.

## The build tree

Everything generated lands under `build/`, which is gitignored:

| Path | Contents |
| --- | --- |
| `build/app/` | `flutter_assets/` with `app.so`, `engine-binaries/`, `flutter-pi/`. |
| `build/os/` | `daemon/`, `cadence/`, `bluetooth/`, `runtime/`, `splash/`, `rootfs/`, `initramfs/`, `kernel/`. |
| `build/recovery/` | The Tempo Recovery RAM-boot pair and `recovery.img`. |
| `build/rust/`, `build/cargo/` | Cargo target and registry caches. |
| `build/toolbox/` | The CLI, GUI bundles, `rust/`, the container-side Flutter build and SDK, device screenshots and diagnostics. |
| `build/sdks/flutter/` | The three provisioned SDKs. |
| `build/bootstrap/` | The bootstrap lock, LFS client staging, and the HOME and pub cache used to validate SDKs. |
| `build/dist/` | The installer package, `images/` and `spft/`. |

Other gitignored inputs: `config.local.yaml`, `.env*` and `.fvm/`.
[Building](building.md) describes what fills each directory and in which
order.
