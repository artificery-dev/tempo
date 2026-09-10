# Releasing

A Tempo release is two sets of files built from one checkout: the firmware
distribution that `toolbox dev dist` writes under `build/dist/`, and the
Toolbox bundles that `toolbox dev toolbox build` writes under `build/toolbox/`
and the Flutter build directory. The firmware carries a public version from
`config.yaml` and a provenance record of the exact sources; every image is
listed with its SHA-256 in a manifest or a `SHA256SUMS` file, and Toolbox
verifies those hashes again before and after it writes to a device. Nothing is
signed. The repository carries no continuous integration configuration, so
every artifact on this page is produced from a checkout by the commands shown
here.

## Components

| Where | What |
| --- | --- |
| `config.yaml` `firmware.version` | The public firmware version. |
| `Cargo.toml` `[workspace.package]` | The version `tempod` reports. |
| `toolbox/app/pubspec.yaml` | The Flutter version field of the Toolbox GUI. |
| `packages/tempo_build/lib/src/distribution.dart` | `toolbox dev dist`: the preflight checks, `images/`, `spft/`, `SHA256SUMS`, `build-provenance.json` and the `.y2-firmware`. |
| `packages/tempo_build/lib/src/tempo_layout.dart` | `tempoInstallerManifest`, the per-image hashes and write ranges in the package manifest. |
| `packages/tempo_build/lib/src/toolbox.dart`, `toolbox_linux.dart` | `toolbox dev toolbox build` and `check`; the resources copied beside each executable; the container SDK on Linux. |
| `packages/tempo_build/lib/src/recovery.dart` | `ensureRecovery` and the `build/recovery/build-state.json` input record. |
| `packages/tempo_build/lib/src/bootstrap.dart` | `firmwareBuildSteps` and the host and credential checks that run before a build. |
| `packages/tempo_usb/rust/src/package.rs`, `firmware.rs` | The package validation Toolbox and `toolbox inspect` apply to a release. |
| `build/dist/`, `build/toolbox/`, `build/recovery/` | Where the release files land. |

## Version numbers

| Version | Lives in | Read by |
| --- | --- | --- |
| Firmware, `0.9.0` | `config.yaml` `firmware.version` | `toolbox dev dist`, which writes it as `firmware.version` in the `.y2-firmware` manifest. `toolbox inspect` reports it and the Toolbox GUI shows it as the package's `Version`. Nothing on the device reads it. |
| Daemon core, `0.1.0` | `Cargo.toml` `[workspace.package] version`, inherited by `daemon/native` | `tempod --version`, the `tempod ... starting` log line and the `version` field of the native control status. |
| Toolbox GUI, `0.1.0+1` | `toolbox/app/pubspec.yaml` | Only the Flutter platform runners, which stamp it into their own bundle metadata. No Tempo code reads it. |
| Dart packages, `0.1.0` | `app/`, `daemon/` and `packages/*/pubspec.yaml` | Nothing; they are pub metadata for workspace packages that are never published. |
| Cadence, `v0.9.0` | `config.yaml` `cadence.release` with `cadence.bundle_sha256` | `toolbox dev cadence fetch`. This pins a dependency and is not a Tempo version. |

A firmware release therefore changes exactly one number, `firmware.version`.
The source commit is not part of the version: `dist` records it separately in
the manifest's `firmware.commit` and in `build-provenance.json`. The Toolbox
and daemon versions move independently of the firmware version, and the
Toolbox's own SDK pin in `toolbox/app/.fvmrc` is unrelated to any of them; see
[Toolbox overview](../toolbox/overview.md#the-independent-sdk-pin).

## Building the distributable set

```sh
toolbox dev workspace analyze
toolbox dev workspace test
toolbox dev daemon check
toolbox dev toolbox check
toolbox dev build
toolbox dev dist --full
toolbox dev toolbox build native
toolbox dev toolbox build web
```

`toolbox dev build` runs the component builds in dependency order and ends
with `dist`; see [Building](building.md). `dist` can then be rerun alone with
`--full` to add the stock boot chain to the SP Flash Tool folder, since the
whole build calls it without that flag. `toolbox build` is not part of the
firmware build and produces the CLI plus the GUI for the host it runs on; a
macOS or Windows GUI is built on that operating system.

## What a firmware release consists of

`dist` writes three things under `build/dist/`.

| Path | Contents |
| --- | --- |
| `<hostname>.y2-firmware` | The installer package Toolbox consumes: `manifest.json` followed by `images/boot.img`, `recovery.img`, `logo.img`, `rootfs.ext4` and `partition-table.bin`, each with its size and SHA-256 and the raw eMMC range it is written to. |
| `images/` | The loose images: `boot.img`, `recovery.img`, `logo.img`, `<hostname>.ext4.gz`, the uncompressed `rootfs.ext4`, `partition-table.bin` and a `SHA256SUMS` covering the first four. |
| `spft/` | The legacy scatter export for SP Flash Tool: `Y2_MT6582_scatter.txt`, `boot.img`, `recovery.img`, `logo.img`, the split rootfs pieces with `rootfs-pieces.json`, `DA.img`, `build-provenance.json`, a `README.md` and a `SHA256SUMS` over all of them. |

The `.y2-firmware` is the release artifact for users. Its manifest never maps
`boot1` or `boot2`, so an install leaves the vendor preloader and LK alone;
the format and the exact ranges are in
[Firmware packages](../toolbox/firmware-packages.md#tempos-own-package). The
`spft/` folder is a secondary artifact that preserves the vendor scatter
layout, and the `README.md` written into it says so.

`--full` changes only `spft/`. It copies the first `preloader_*.bin` in
`firmware.stock_rom`, `MBR`, `EBR1`, `lk.bin` and `secro.img` beside the
scatter, marks those rows as downloads in `Y2_MT6582_scatter.txt`, and adds
them to `SHA256SUMS`, so SP Flash Tool can bring back a device whose boot
chain is gone. The installer package is identical with and without the flag;
`dist` prints a reminder that the raw preloader stays SPFT-only.
`--with-rootfs` is accepted and changes nothing, because the rootfs is always
included. The stock inputs behind `--full` are described in
[Firmware inputs](../platform/firmware-inputs.md).

## What a Toolbox release consists of

`toolbox dev toolbox build [target]` produces one bundle per target. Every
native bundle carries the same resources beside its executable: the
`tempo-usb` helper, `DA.img`, `70-tempo-recovery.rules`, and a `recovery/`
directory with `ramboot-DA.bin`, `payload.bin` and `preloader.bin` copied
from `build/recovery`. The build stops if any of the three recovery files is
missing, and on Unix hosts it normalises the bundle to modes `755` and `644`
so a root-owned installation stays readable.

| Target | Output | Contents |
| --- | --- | --- |
| `cli` | `build/toolbox/cli/` | `toolbox`, or `toolbox.exe` on Windows, compiled with `dart compile exe`, plus the resources above. |
| `linux` | `build/toolbox/flutter/linux/<arch>/release/bundle/` | The Flutter Linux bundle with the resources copied in. Built in the toolchain container with the SDK staged under `build/toolbox/linux-sdk/`. |
| `macos` | `toolbox/app/build/macos/Build/Products/Release/*.app` | The app bundle; the resources sit in `Contents/MacOS` and modes are normalised over the whole `.app`. |
| `windows` | `toolbox/app/build/windows/<arch>/runner/Release/` | The runner directory with the resources copied in. |
| `web` | `build/toolbox/flutter/web/` on Linux, otherwise `toolbox/app/build/web/` | `flutter build web --no-web-resources-cdn` over `toolbox/app/web/`, which holds the `wasm-bindgen` output in `pkg/` and a copy of `DA.img`. No helper and no recovery images. |
| `apk`, `ios` | The Flutter build directory | `flutter build` only; no helper, no resources. |

`native`, the default, builds the CLI and then the GUI for the host platform.
`--gui-only` skips the CLI. On macOS and Windows the helper is built with the
host's `cargo`, because the Linux container cannot link a native USB executable
for those systems. Which of these platforms run end to end is recorded in
[Toolbox overview](../toolbox/overview.md#platforms); the recovery images and
how Toolbox boots them are in
[Tempo Recovery](../platform/recovery.md#image-packaging).

## The provenance record

`dist` writes `build/dist/spft/build-provenance.json` and puts the same commit
into the package manifest as `firmware.commit`.

| Field | Value |
| --- | --- |
| `commit` | `HEAD` of the Tempo checkout. |
| `worktree_status` | The lines of `git status --porcelain`, so a build from a dirty tree says so. |
| `submodules` | For `platform/kernel/linux` and `app/flutter-pi/flutter-pi`: the commit, a SHA-256 of `git diff HEAD --binary`, and a hash of each untracked file. |
| `kernel_source` | `build/os/kernel/tempo-source.json`, described in [Kernel](../platform/kernel.md#provenance). |
| `bluetooth_payload` | `build/os/bluetooth/build-manifest.json`. |
| `kernel_config_sha256` | The hash of the kernel `.config` that was built. |
| `public_config_sha256` | The hash of `config.yaml`. |
| `dart_lock_sha256` | The hash of `pubspec.lock`. |

`config.local.yaml` is not hashed and not recorded, since it holds the device
credentials. Recovery keeps its own record in `build/recovery/build-state.json`:
the kernel commit and a hash of every input file, which is what lets
`toolbox build` reuse the images when nothing changed. A release built from
a tree with uncommitted changes is not refused, but the Recovery and kernel
builds do refuse an uncommitted kernel checkout, so `submodules` can only
report a clean diff for the kernel.

## Integrity and signing

Integrity rests on SHA-256 throughout and on nothing else.

| Where | What is hashed |
| --- | --- |
| `manifest.json` in the `.y2-firmware` | Every image, padded to 512 bytes, with its size. The packaging script hashes each image as it streams it into the ZIP, then reopens the archive and hashes every entry again before renaming the file into place. |
| `build/dist/images/SHA256SUMS`, `build/dist/spft/SHA256SUMS` | The loose images and the scatter folder, in `sha256sum` format. |
| `rootfs-pieces.json` | The hash of the whole rootfs image; `dist` reassembles the split pieces and refuses a set that does not reproduce it. |
| The daemon bundle `manifest.json` and the Cadence bundle manifest | Each staged file; rootfs staging and `daemon deploy` verify them, and `cadence fetch` checks the tarball against `cadence.bundle_sha256`. |

On the installing side, Toolbox hashes each image again while extracting it to
its staging directory, refuses a staged image that has since changed, and
reads every range back after writing it; see
[Device operations](../toolbox/device-operations.md#readback-verification).
`toolbox inspect FILE` validates a package without a device.

There is no signing. No command signs a package, a bundle, a manifest or a
`SHA256SUMS` file, the Toolbox verifiers check hashes and ranges only, and the
checkout contains no signing keys or certificates. A release is identified by
`firmware.version`, `firmware.commit` and the hashes above.

## Checks before packaging

The tooling will not package until these pass.

| Stage | Checks |
| --- | --- |
| `toolbox dev build` | Linux x64 host; `config.local.yaml` supplies a password or SSH key and not the example password; rootful Podman can loop-mount and run ARM binaries. |
| `os kernel build`, `os recovery build` | The kernel submodule has no uncommitted changes and holds the Y2 device tree. Recovery's build script runs its charge-policy, status and transfer tests before it builds the images. |
| `dist` | `device.partitions` equals `TempoLayout`; `boot.img` starts with `ANDROID!` and fits `bootimg_size`; the rootfs fits `rootfs_size`, is not mounted, passes `e2fsck -fn` and holds no player-specific radio capture; the stock scatter is present. Then every image is checked against its partition span before the scatter is written. |
| `toolbox build` | `platform/firmware/DA.img` exists; the three Recovery images exist; on Linux, dependencies are resolved on the host and every resolved package is a local directory. |
| `toolbox check` | `cargo fmt --check`, `cargo test --locked` and `cargo clippy` with warnings as errors for the USB engine, the browser suites on Node, `flutter analyze` and `flutter test` in `toolbox/app`, `dart analyze` and `dart test` in `toolbox/cli`. |
| `workspace analyze`, `workspace test`, `daemon check` | Every Dart root with its pinned SDK, plus `cargo fmt`, Clippy and `dart analyze` for the daemon. |

`toolbox check` and the workspace commands are not invoked by `build` or
`dist`; they are run by hand before a release, as in the sequence above. What
each suite covers is in [Testing and checks](testing.md).

## The acceptance pass

There is no single acceptance command. The pass is the set of checks the
tooling already provides against a built release and a real Y2, run in this
order:

| Step | Command | What it establishes |
| --- | --- | --- |
| Inspect the package | `toolbox inspect build/dist/<hostname>.y2-firmware` | The archive rules and manifest validate, the identity and image count are as expected, and no mapping targets `boot1`. |
| Install it | Toolbox Backup & Restore, or `toolbox install FILE --yes` | Every image is staged, hashed, written and read back on a powered-off player through Tempo Recovery. |
| Check the running player | `toolbox dev device status` | The player answers over the USB link and reports its uptime, kernel, network, service and disk state. |
| Capture the state | `toolbox dev device collect-sysinfo`, `toolbox dev device screenshot` | The kernel, device tree, buses and units under `build/toolbox/device/sysinfo-<stamp>/`, and the display as a PNG. |
| Exercise audio | `toolbox dev diagnostics capture-a2dp`, `analyze-tone` | Bluetooth playback is continuous from the host's side. |
| The user's view | `toolbox diagnose` | The read-only support report an end user can produce from the same release. |

The device commands and their outputs are described in
[Working with a device](device.md#logs-and-diagnostics) and
[Diagnostics](../platform/diagnostics.md); the install path and its policies in
[Device operations](../toolbox/device-operations.md). A release whose package
fails `inspect`, whose install fails readback, or whose player does not answer
`device status` is rebuilt, not shipped.
