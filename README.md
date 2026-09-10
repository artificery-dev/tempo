# Tempo

A Linux based media player firmware for the Innioasis Y2.

Tempo turns a MediaTek music player into a small, open
Linux device, with a player interface that feels like it belongs on a finished
product rather than a hobby flash. It runs mainline Linux and a Debian userland,
draws its UI with Flutter on the device's own GPU, and drives it all from the
Y2's click wheel.

It installs onto stock hardware with no case opening and no soldering. Normal
installation preserves the MediaTek boot chain so it can be used for recovery.

## Features

- **Real Linux underneath.** Mainline Linux with a Debian armhf userland, so you
  get `apt`, systemd, ssh, and the rest of a normal Linux system on a device that
  shipped locked to a 2014 Android kernel.
- **A fluid, GPU-drawn interface.** The UI is a Flutter app rendered on the Y2's
  Mali GPU through the `lima` driver, not smeared onto the framebuffer by the CPU.
- **Click-wheel navigation that feels right.** An iPod-style input grammar (jog
  the wheel to move, press to select, hold buttons as chords) with Cupertino-style
  overscroll, so scrolling long song lists feels natural instead of mechanical.
- **A boot that looks finished.** An animated splash comes up under the vendor
  bootloader and holds, animating, all the way until the interface paints its
  first real frame. No black gaps, no flicker, no console spew.
- **Recovery tools.** Toolbox provides explicit backup, restore and installation
  operations. Preloader writes are disabled by default and require a separate
  acknowledgement. Make and retain a complete backup before installation.
- **Made to be hacked on.** A USB serial console and USB networking mean you can
  `ssh` straight into the device, and a desktop emulator runs the exact same
  interface so you can build and test the UI without the hardware in hand.
- **Shared device services.** The on-device daemon owns battery and card
  monitoring, library scans, settings, radio control and Bluetooth playback
  commands, independently of the player interface.

## The device

The Innioasis Y2 is a click-wheel media player built on a MediaTek MT6582: a
quad-core Cortex-A7 with about 992 MB of RAM, a 480×360 DSI panel, a Mali-400
GPU, and a capacitive click wheel. Stock, it runs an old Android or a community
Rockbox build. Tempo replaces that software wholesale while using every one of
those pieces of hardware.

## Project status

Tempo is undergoing release preparation. Hardware bring-up works on the Y2;
Toolbox hardware parity and platform validation are still in progress.
The reorganized runtime has passed sustained audio/video checks on the Y2.
Release validation is ongoing; review the component documentation for current
platform support.

## Repository layout

| Directory | Owner and purpose |
| --- | --- |
| `app/` | Device Flutter app, pinned `flutter-pi` embedder, patches and engine pairing. |
| `toolbox/app/` | Toolbox Flutter UI and emulator, using mocked device services. Desktop uses a second native window in the same process; mobile uses a route. |
| `toolbox/cli/` | Native command-line presentation for shared Toolbox operations. |
| `daemon/` | Dart service host, media database, settings and radio operations; private Rust hardware core under `native/`. |
| `packages/tempo_core/` | Player UI and service interfaces shared by the app and emulator. |
| `packages/player_api/`, `packages/daemon_client/` | Player contracts and daemon transports. |
| `packages/toolbox_core/`, `packages/tempo_usb/` | Shared device-operation policy, transports and native/Wasm USB engine. |
| `packages/tempo_build/` | Repository configuration, SDK discovery and Dart build/development commands. |
| `packages/tempo_kms/` | Native display library. |
| `platform/` | Kernel, rootfs, production Bluetooth bootstrap, firmware, splash and cross toolchain. |
| `build/` | Generated app, Toolbox, OS and Rust products; final image sets under `build/dist/`. |

This public source repository excludes historical reverse-engineering material.
Toolbox imports legacy scatter ROMs directly;
no external SP Flash Tool installation is needed.

The kernel lives in our [Linux fork](https://github.com/artificery-dev/linux),
on `tempo/innioasis-y2`, based on the tested Linux v6.12 revision. The
`platform/kernel/linux` submodule pins its exact commit; builds no longer apply
a patch stack. See [kernel development](platform/kernel/README.md).

The app and shared Dart packages use the root pub workspace. Toolbox keeps its
own SDK resolution; do not change the device Flutter pin without checking its
engine/AOT pairing. The daemon compiler has a separate explicit version in
`config.yaml`. The root Cargo workspace contains the daemon native core and
`tempo_kms`; the USB engine and archived demos have independent workspaces.

## Development

Shared operations live behind `toolbox dev`; `toolbox dev --help` lists the
areas, and `toolbox dev os rootfs --help` lists a component's commands. Component
`tool/*.dart` entry points call the same APIs. There is no Just dependency.
Keep machine configuration and credentials in ignored `config.local.yaml`,
starting from `config.local.example.yaml`.

Development command overrides are listed in [.env.example](.env.example);
player and daemon service overrides are in [.env.device.example](.env.device.example).

The host tooling contract is Dart and Podman. Additional language runtimes and
build tools belong in the container; Python, Node and other container tools are
allowed. Git and standard Linux utilities provide checkout/authentication support.
The complete firmware build currently runs on Linux x64. Bootstrap provisions
the pinned Flutter SDKs and Git LFS client; FVM is not required. SDKs live in
`build/sdks/flutter/`, and Toolbox independently uses `toolbox/app/.fvmrc`.

Linux Toolbox GUI/CLI builds, native Rust builds, and browser tests run inside
Podman. Toolbox can copy a pinned Linux SDK cache or fetch its pinned SDK in
the container. Bootstrap resolves package dependencies using the host's Git/SSH
credentials, including access to the private Cadence repository.

Rootfs build, stage and shell use privileged rootful Linux Podman with
sudo/root access. The container supplies debootstrap, QEMU and filesystem tools.
`TEMPO_ROOTFS_HOST=1` retains the original host path for compatibility. Rootfs
operations and distribution packaging share an exclusive checkout lock.
Device deployment keeps host SSH and its agent/network configuration. macOS,
Windows and mobile native builds still require their platform SDKs; Linux
container checks do not validate those platforms.

From a clean checkout, run the pure Dart CLI from its own package directory:

```sh
cd toolbox/cli
dart run bin/toolbox.dart dev bootstrap \
  --config /absolute/path/to/config.local.yaml
cd ../..
build/toolbox/cli/toolbox dev build
```

The import is optional when local configuration is already present. Existing
configuration is preserved. Set an SSH public key or
your own password in the configuration; do not use the example password.
Bootstrap checks rootful Podman mounting and ARM execution, initializes
submodules, hydrates required firmware blobs, resolves dependencies and compiles the CLI.
Rerun it after fixing a failed prerequisite; completed SDK downloads are reused.
Add `--build` to bootstrap to run the full build immediately afterwards.

`dev build` builds the app, daemon, rootfs and kernel in dependency order and
writes `build/dist/tempo.y2-firmware` for the installer, alongside SPFT images.
It rebuilds the configured rootfs image and does not access the device.
`toolbox dev workspace analyze` and `toolbox dev workspace test` run the
development checks. Individual component commands remain available.

Bluetooth initialization uses the bundled stock modem firmware, generated
protocol structures, and a temporary RAM filesystem. No device captures are
required or included; see [radio initialization](docs/platform/radio-initialization.md). Rootfs staging
requires a complete verified ARM daemon bundle, including its native libraries.
`toolbox dev os rootfs stage` updates an existing image. Use `toolbox dev device`
for running hardware and `toolbox dev emulator run` for the mocked emulator.
See [daemon setup](daemon/README.md), [Toolbox](toolbox/app/README.md), and
[recovery](platform/recovery/README.md).

## Installation

Use Toolbox's **Backup & Restore** workflow. Create and retain a complete backup,
then choose **Flash a firmware**, select a `.y2-firmware` package, review the
options and connect the player when prompted. Toolbox can start Tempo Recovery
in RAM on a powered-off player. Keep readback verification enabled for a checked
installation. Preloader writes are disabled by default.

See [Toolbox](toolbox/app/README.md) for supported platforms and
[Tempo Recovery](platform/recovery/README.md) for the transfer environment.
