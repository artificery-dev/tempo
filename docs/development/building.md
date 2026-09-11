# Building

`toolbox dev build` produces the complete firmware from a bootstrapped
checkout: the player bundle and its embedder, the daemon, the Cadence
bundle, the splash, the root filesystem, the kernel and finally the
distribution set. It runs the component commands in dependency order and
stops at the first failure, and each of those commands can be run on its own
to rebuild one piece. Nothing in the build touches a device; getting the
output onto hardware is covered in [Working with a device](device.md).

## Components

| Where | What |
| --- | --- |
| `packages/tempo_build/lib/src/bootstrap.dart` | `firmwareBuildSteps`, the ordered step list, and `firmwareBuildCommand`. |
| `packages/tempo_build/lib/src/embedder.dart` | `app flutter-pi engine` and `build`. |
| `packages/tempo_build/lib/src/app.dart` | `app build`, the bundle and the AOT snapshot. |
| `packages/tempo_build/lib/src/daemon.dart`, `daemon_native.dart` | `daemon build` for host and ARM, with the Rust core. |
| `packages/tempo_build/lib/src/cadence.dart` | `cadence fetch`, the pinned `cadenced` release bundle. |
| `packages/tempo_build/lib/src/splash.dart` | `os splash assets` and `build`. |
| `packages/tempo_build/lib/src/rootfs.dart`, `rootfs_container.dart` | `os rootfs build` and `stage`. |
| `packages/tempo_build/lib/src/bluetooth.dart`, `system_runtime.dart` | `os bluetooth build` and `os runtime build`, run before the rootfs. |
| `packages/tempo_build/lib/src/kernel.dart` | `os kernel build`, the initramfs and `boot.img`. |
| `packages/tempo_build/lib/src/recovery.dart` | `os recovery build` and the build cache `dist` and Toolbox use. |
| `packages/tempo_build/lib/src/distribution.dart` | `dist`: the installer package and the SP Flash Tool folder. |
| `build/`, `build/dist/` | Intermediate output per component, and the final image set. |

## The pipeline

`toolbox dev build` accepts no arguments. Before the first step it checks
that the host is Linux x64, that `config.local.yaml` supplies a password or
SSH key and does not still hold the example password, and that rootful
Podman can loop-mount and run ARM binaries; the last check repeats on every
build because binfmt registration is kernel state that a reboot clears. Then
it dispatches these commands in order, printing a `== toolbox dev ... ==`
banner before each:

| Step | Command | Output |
| --- | --- | --- |
| 1 | `app flutter-pi engine` | `build/app/engine-binaries/arm/`: the engine libraries, `icudtl.dat` and `gen_snapshot`, fetched by sparse checkout at `flutter.engine_binaries.commit`. |
| 2 | `app flutter-pi build` | `build/app/flutter-pi/flutter-pi`, cross-built with CMake in the container after applying `app/flutter-pi/patches/`. |
| 3 | `app build --release` | `build/app/flutter_assets/` with the ARMv7 AOT snapshot `app.so`. |
| 4 | `daemon build --target arm` | `build/os/daemon/arm/bundle/`: `bin/tempod`, `bin/tempod-native`, `lib/libtempod_native.so` and a `manifest.json` of SHA-256 hashes. |
| 5 | `cadence fetch` | `build/os/cadence/arm/bundle/`, the verified `cadenced` release bundle. |
| 6 | `os splash assets` | The boot PNG, plymouth theme images and the core swirl asset, rendered from the SVG into the source tree. |
| 7 | `os splash build` | `build/os/splash/logo.bin`, the LOGO image. |
| 8 | `os rootfs build` | `build/os/rootfs/<hostname>.ext4` and `build/os/rootfs/plymouth-payload/`. |
| 9 | `os kernel build` | `build/os/kernel/boot.img`, with `build/os/initramfs/`. |
| 10 | `dist` | `build/dist/<hostname>.y2-firmware`, `build/dist/images/` and `build/dist/spft/`. |

The order is dictated by inputs. The app needs the engine so that its
snapshot comes from the matching `gen_snapshot`; the rootfs stages the app
bundle, the embedder, the daemon bundle and the Cadence bundle, so all four
come first; the kernel's initramfs packs the plymouth payload that the rootfs
build produces, so the kernel comes after the rootfs; and `dist` needs
`boot.img`, the rootfs image and the splash.

## The player

`app flutter-pi engine` clones only the seven files Tempo needs from the
engine binaries repository and refuses an incomplete or mismatched fetch.
`app flutter-pi build` checks the submodule is at `flutter.flutter_pi.commit`,
applies each patch in `app/flutter-pi/patches/` in name order, skipping any
already applied, copies `plugins/plymouth_handoff.c` into the source tree and
configures CMake for OpenGL with the GStreamer video plugin on and Vulkan,
session switching and the audio player off. `TEMPOD_SOCKET` is compiled in
from `daemon.socket`. `app flutter-pi test` compiles and runs the handoff
client test in the container.

`app build` runs `flutter pub get` and `flutter build bundle` into
`build/app/flutter_assets`. With `--release` it also runs the frontend server
in AOT mode against `package:tempo/main.dart` and then the pinned
`gen_snapshot` to produce a stripped `app.so`, after checking that the SDK's
`engine.version` equals the fetched engine's `flutter.version`. Without
`--release` the bundle is a debug, JIT build. See
[flutter-pi and engine pairing](../app/flutter-pi.md).

## The daemon and Cadence

`daemon build` compiles `bin/tempod.dart` with `dart build cli` using the
daemon's own pinned Dart, which must report `daemon.dart_version`. The
default target is `host`; `--target arm` cross-compiles for the device and
verifies that the result is an ARM32 ELF. Unless `--dart-only` is given it
then builds the `tempod` crate, on the host side through the container for
`host` and with `cargo build --target armv7-unknown-linux-gnueabihf` for
`arm`, with the socket path, state directory, sample interval and user uid
baked in from `config.yaml`. The bundle's `manifest.json` records the Dart
version, target, whether native pieces are included, and a hash per file;
rootfs staging and `daemon deploy` verify it.

`cadence fetch` reads `cadence.repository`, `cadence.release` and
`cadence.bundle_sha256`, asks the Forgejo release API for the armhf tarball,
downloads it to `build/os/cadence/armhf/` unless a copy with the right hash
is there, and extracts it to `build/os/cadence/arm/bundle`. The bundle's own
manifest is verified: every file's hash, that `bin/cadenced`,
`lib/libsqlite3.so` and `lib/libcadence_probe.so` are present and are 32-bit
ARM ELF, and that the licence is MIT. See
[Cadence integration](../app/cadence-integration.md).

## The operating system

`os rootfs build` first runs `os bluetooth build` and `os runtime build` on
the host, then hands the rest to the rootful container, which runs
debootstrap, installs the package groups, applies the overlay and stages the
runtime. Staging requires a verified daemon bundle, Cadence bundle, system
runtime and Bluetooth bootstrap; the app bundle, embedder and engine are
staged when present and reported as not staged otherwise, which is what lets
`os rootfs stage` refresh an existing image after an `app build`. The
details are in [Root filesystem](../platform/rootfs.md).

`os kernel build` verifies the submodule checkout is committed, records its
provenance, renders and builds the initramfs with the plymouth payload, then
configures and compiles the kernel and packs `boot.img`, refusing an image
larger than `device.partitions.bootimg_size`. See
[Kernel](../platform/kernel.md) and [Boot splash](../platform/splash.md).

`os recovery build` is not in the step list. `dist` and native Toolbox builds
call it themselves: `dist` always rebuilds it, and `toolbox build` rebuilds
it when the hashed inputs or outputs under `build/recovery/` have changed.
See [Tempo Recovery](../platform/recovery.md).

## Distribution

`dist` refuses to run unless `device.partitions` matches the `TempoLayout`
constants, `boot.img` starts with `ANDROID!` and fits its partition, the
rootfs image fits its partition and is not mounted, `e2fsck -fn` passes and
the radio image check passes. It then builds Recovery, rebuilds the LOGO from
the stock template, gzips the rootfs when the compressed copy is older than
the image, and writes:

| Path | Contents |
| --- | --- |
| `build/dist/images/` | `boot.img`, `recovery.img`, `logo.img`, `<hostname>.ext4.gz`, `rootfs.ext4` and `SHA256SUMS`. |
| `build/dist/<hostname>.y2-firmware` | The installer package Toolbox consumes, with its manifest carrying `firmware.version` and the source commit. |
| `build/dist/spft/` | The legacy scatter export: `Y2_MT6582_scatter.txt`, `boot.img`, `recovery.img`, the split rootfs pieces and `rootfs-pieces.json`, `DA.img`, `build-provenance.json`, a `README.md` and `SHA256SUMS`. |

`build-provenance.json` records the checkout commit and worktree status, both
submodule commits with a hash of any uncommitted diff, the kernel source
record, the Bluetooth payload manifest, and hashes of the kernel `.config`,
`config.yaml` and `pubspec.lock`. `--full` adds the stock preloader, `MBR`,
`EBR1`, `lk.bin` and `secro.img` to the scatter folder so SP Flash Tool can
restore a device in any state; the installer package still never writes
BOOT1. `--with-rootfs` is accepted and ignored, since the rootfs is always
included. Rootfs operations and `dist` share an exclusive lock on the
checkout. The package format is described in
[Firmware packages](../toolbox/firmware-packages.md).

## Rebuilding one piece

Each step is an ordinary `toolbox dev` command, so after a change rerun the
step that owns it and anything downstream that consumes its output:

| Changed | Rerun |
| --- | --- |
| Dart in `app/` or a shared package | `app build --release`, then `os rootfs stage` or `app deploy`. |
| `daemon/` | `daemon build --target arm`, then `os rootfs stage` or `daemon deploy`. |
| `cadence.release` in `config.yaml` | `cadence fetch`, then `os rootfs stage`. |
| The overlay, units or package lists | `os rootfs build`, then `os kernel build` and `dist`. |
| `platform/kernel/linux` or `y2.config` | `os kernel build`, then `dist` or `device flash-boot`. |
| `platform/splash/` | `os splash assets`, `os splash build`, then `dist` or `device flash-logo`. |
| `platform/recovery/` | `os recovery build`, then `dist` or `toolbox build`. |

`app clean`, `app flutter-pi clean`, `daemon clean`, `os kernel clean`,
`os rootfs clean`, `os splash clean` and `emulator clean` remove the matching
output; `os rootfs clean` also unmounts a still-mounted image first.
Removing `build/` entirely is the one full clean, after which bootstrap
restores the SDKs, LFS client, engine and CLI.

Toolbox itself is not part of `toolbox dev build`. `toolbox build` produces
the CLI and the desktop GUI, or the web assets, with its own SDK pin; see
[Toolbox overview](../toolbox/overview.md).
