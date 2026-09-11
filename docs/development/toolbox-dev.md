# The toolbox dev command reference

`toolbox dev` is the developer side of the Toolbox CLI. Its first word
selects an area and the second an action; `toolbox dev --help` prints the
area list, `toolbox dev <area> --help` lists the actions, and
`toolbox dev <area> <action> --help` describes one command without needing a
checkout, an SDK or a device. `--repo PATH` names the checkout when it cannot
be found from the working directory or `TEMPO_REPO`. A failed command prints
its reason and exits non-zero; usage errors exit 2, and a second bootstrap or
rootfs operation on the same checkout exits 73.

## Components

| Where | What |
| --- | --- |
| `toolbox/cli/bin/toolbox.dart` | The CLI entry point; every `dev` invocation goes to `runDeveloperCommand`. |
| `toolbox/cli/lib/command_help.dart` | Help for the end-user commands (`backup`, `install`, `restore` and the rest). |
| `packages/tempo_build/lib/src/commands.dart` | The dispatcher, the area summary, and `config`, `secrets`, `toolchain` and `workspace`. |
| `packages/tempo_build/lib/src/developer_help.dart` | The per-command usage and descriptions behind `--help`. |
| `packages/tempo_build/lib/src/*.dart` | One file per area, named after it. |
| `app/tool/`, `daemon/tool/`, `toolbox/tool/`, `platform/*/tool/` | `dart run` entry points that forward to these routes. |

The end-user commands, `toolbox device`, `backup`, `restore`, `install`,
`inspect`, `doctor` and `diagnose`, are covered in
[Device operations](../toolbox/device-operations.md).

## Setup and the whole build

| Command | What it does |
| --- | --- |
| `bootstrap [--config FILE] [--build]` | Prepare a clean Linux x64 checkout: import local configuration, check Git and Podman, init submodules, build the toolchain, pull LFS firmware, provision SDKs, resolve dependencies, fetch the engine, compile the CLI. |
| `build` | Run the complete firmware build in dependency order, ending with `dist`. See [Building](building.md). |
| `dist [--full] [--with-rootfs]` | Package `boot.img`, the splash and the rootfs into `build/dist/`: the `.y2-firmware` installer, `images/` and the SP Flash Tool folder. `--full` adds the stock boot chain to the SPFT folder. |

## Configuration

| Command | What it does |
| --- | --- |
| `config get KEY [--raw]` | Print one scalar from the merged configuration. |
| `config list KEY [--raw]` | Print a list value, one item per line. |
| `config json [KEY] [--raw]` | Print the configuration, or one subtree, as JSON. The password is redacted unless `--raw`. |
| `config has [KEY]` | Exit 0 when the key is present and non-empty, 1 otherwise. No output. |
| `secrets status` | Report whether `config.local.yaml` exists and whether the password is unset, hashed or plaintext. The default action. |
| `secrets hash` | Hash a plaintext local password with `openssl passwd -6` in place and set the file to mode `0600`. |
| `secrets is-hashed` | Exit 0 when the configured password is already a crypt hash. |

## Toolchain

| Command | What it does |
| --- | --- |
| `toolchain build [podman build arguments]` | Build the `tempo-toolchain` image. |
| `toolchain rebuild [podman build arguments]` | The same with `--no-cache --pull`. |
| `toolchain run COMMAND [arguments]` | Run one command in the container with the checkout mounted. |
| `toolchain shell [zsh arguments]` | Open zsh in the container. |
| `toolchain info` | Inspect the image and print the gcc, rustc and dtc versions. |
| `toolchain clean` | Remove the image. |

See [Toolchain container](../platform/toolchain.md).

## Workspace

| Command | What it does |
| --- | --- |
| `workspace get [pub get arguments]` | `pub get` at the workspace root and in each independently resolved package, with the SDK each one pins. |
| `workspace analyze [analyzer arguments]` | Analyze every first-party package root and report the failures together. |
| `workspace test [test arguments]` | Test every package root that has a `test/` directory; the daemon goes through `daemon test`. |
| `workspace format [dart format arguments]` | `dart format` over the same roots. |

See [Testing and checks](testing.md).

## App

| Command | What it does |
| --- | --- |
| `app build [--release]` | Build the Flutter bundle into `build/app/flutter_assets`. `--release` adds the ARMv7 AOT snapshot from the pinned engine. |
| `app deploy [--release] [--dry-run]` | Stage the bundle over SSH with checksums, restart the player and verify, rolling back on failure. |
| `app attach [--dry-run]` | `flutter attach` to the debug build's VM service on the device. |
| `app clean` | Remove the bundle and the AOT intermediate; keep the engine and embedder. |
| `app flutter-pi engine` | Fetch the pinned engine binaries and `gen_snapshot` into `build/app/engine-binaries`. |
| `app flutter-pi build` | Apply the embedder patches and cross-build flutter-pi in the container. |
| `app flutter-pi test` | Compile and run the native handoff client test. |
| `app flutter-pi rev` | Print the flutter-pi submodule commit. |
| `app flutter-pi clean` | Remove the embedder build output. |

## Daemon and Cadence

| Command | What it does |
| --- | --- |
| `daemon build [--target host\|arm] [--dart-only]` | Build the `tempod` bundle under `build/os/daemon/<target>/bundle`. Default target `host`; `--dart-only` skips the Rust core. The default action. |
| `daemon deploy [--dry-run]` | Deploy the ARM bundle and service units to the device and verify them. |
| `daemon test [test arguments]` | Run the crate's tests, then the Dart tests with an isolated SQLite asset map. Extra arguments go to `package:test`. |
| `daemon check` | `cargo fmt --check`, Clippy on `tempod`, and Dart analysis. |
| `daemon clean` | Remove `build/os/daemon`. |
| `cadence fetch` | Download and verify the pinned `cadenced` release bundle into `build/os/cadence/arm/bundle`. |

## Emulator

| Command | What it does |
| --- | --- |
| `emulator run [flutter run arguments]` | Run Toolbox as the emulator with its own SDK pin and the emulator define; `-d` selects a device, defaulting to the host platform. |
| `emulator mcp [arguments]` | Run the emulator MCP server over stdio, which drives the running emulator through its VM service. |
| `emulator clean` | Remove the VM service discovery files under `~/.cache/tempo` and `build/toolbox/emulator`. |

See [The emulator](emulator.md).

## Toolbox

| Command | What it does |
| --- | --- |
| `toolbox build [native\|web\|cli\|linux\|macos\|windows\|apk\|ios] [--gui-only] [build arguments]` | Build Toolbox with its pinned SDK. Default `native`: the CLI plus the host's desktop GUI, with the `tempo-usb` helper, `DA.img`, the udev rule and the Recovery images packaged beside them. `web` builds the Wasm engine and the browser app. On Linux the Flutter and Rust work runs in the container. |
| `toolbox check` | `cargo fmt`, tests and Clippy for the USB engine, the browser tests, then Flutter analyze and test for the GUI and Dart analyze and test for the CLI. |

See [Toolbox overview](../toolbox/overview.md).

## Operating system

| Command | What it does |
| --- | --- |
| `os kernel build` | Prepare the source, render and build the initramfs, compile the kernel and DTB, pack `boot.img`. |
| `os kernel prepare` | Verify the submodule checkout is committed and record its provenance. |
| `os kernel bootimg [--dtb FILE] [--ramdisk FILE] [--output FILE] [--max-size BYTES]` | Pack an existing build into `boot.img`. |
| `os kernel rev` | Print the kernel submodule commit. |
| `os kernel reset` | Delete the provenance record; refuse if the checkout is dirty. |
| `os kernel clean` | Remove `build/os/kernel` and `build/os/initramfs`. |
| `os initramfs build` | Render and build the initramfs under `build/os/initramfs`. The default action. |
| `os initramfs render` | Render the `init` script and manifests without compiling. |
| `os rootfs build` | Build the Debian image in the rootful container, after `os bluetooth build` and `os runtime build`. |
| `os rootfs stage` | Stage the current runtime, units and configuration into the existing image. |
| `os rootfs shell [-- COMMAND...]` | Chroot into the image, or run one command there. |
| `os rootfs plan` | Print the resolved settings, package count and credential presence. The default action. |
| `os rootfs clean` | Unmount if needed and remove `build/os/rootfs`. |
| `os rootfs stage-plymouth TREE OUTPUT` | Collect the plymouth runtime payload from a root filesystem tree. |
| `os runtime build` | Cross-compile `tempo-system` and `tempo-system.so` into `build/os/runtime`. |
| `os bluetooth build` | Cross-compile the modem bootstrap and `mmio.so` into `build/os/bluetooth`, with the vendor modem firmware and unit. |
| `os recovery build` | Build Tempo Recovery in the container and pack `build/recovery/recovery.img`. The default action. |
| `os splash build [PNG] [--output FILE] [--template FILE] [--index N] [--bare] [--near-black]` | Build a LOGO image from a PNG over the stock template. The default action. |
| `os splash assets` | Render the boot PNG, plymouth images and the core swirl from the SVG. |
| `os splash info IMAGE` | Print a LOGO image's block table. |
| `os splash extract IMAGE DIRECTORY` | Decode the blocks to PNG and raw files. |
| `os splash install` | Install the built splash assets on the connected device. |
| `os splash harvest` | Collect splash material from the connected device. |
| `os splash clean` | Remove `build/os/splash`. |

See [Kernel](../platform/kernel.md), [Root filesystem](../platform/rootfs.md),
[Boot splash](../platform/splash.md), [Tempo Recovery](../platform/recovery.md)
and [Radio initialization](../platform/radio-initialization.md).

## Device

These connect over SSH to `TEMPO_DEVICE_HOST`, by default the gadget address
in `networking.usb_gadget.address`, as `TEMPO_DEVICE_USER`, by default
`user.name`.

| Command | What it does |
| --- | --- |
| `device ssh [remote command]` | Open a shell or run one command on the device. |
| `device status` | Print hostname, uptime, kernel, command line, addresses, the Tempo units and disk usage. |
| `device link [up\|down\|reset] [--share]` | Configure the Linux host side of the USB network link. Default `up`; `--share` enables Internet sharing. |
| `device reboot`, `device poweroff` | Check the device, then request the action. |
| `device screenshot [NAME]` | Capture the panel to `build/toolbox/device/screenshots/NAME.png` with a static helper compiled in the container. |
| `device collect-sysinfo` | Collect system diagnostics under `build/toolbox/device`. |
| `device flash-boot [IMAGE] [--no-reboot] [--dry-run] [--force]` | Write `boot.img` through the running device, defaulting to the built distribution or kernel image. |
| `device flash-logo [IMAGE] [--scan] [--dry-run]` | Locate the live LOGO partition, back it up, and write the image. `--scan` only locates it. |
| `device install-rootfs [IMAGE] [--sd DIRECTORY \| --reboot]` | Copy a rootfs image to the device's card for reinstall on next boot, or to a host-mounted card with `--sd`. |
| `device splash-install`, `device splash-harvest` | Aliases of the `os splash` device actions. |

See [Working with a device](device.md).

## Diagnostics

These need no checkout.

| Command | What it does |
| --- | --- |
| `diagnostics capture-a2dp [BLUETOOTH_ADDRESS] [OUTPUT_DIRECTORY]` | Record a paired A2DP peer into a host null sink as 48 kHz stereo WAV under `build/btdiag` by default. |
| `diagnostics analyze-tone WAV [--silence-db DB] [--minimum-gap-ms MS]` | Measure continuity and gaps in a recorded test tone. Exit 0 continuous, 1 no tone, 2 dropouts, 64 invalid input. |

## Entry points without the compiled CLI

Each component keeps `tool/*.dart` files that forward to one route, so
`dart run` from the checkout root reaches the same code:

| Entry point | Route |
| --- | --- |
| `app/tool/build.dart`, `deploy.dart`, `attach.dart`, `clean.dart` | `app ...` |
| `daemon/tool/build.dart`, `deploy.dart`, `check.dart`, `clean.dart` | `daemon ...` |
| `toolbox/tool/build.dart`, `check.dart` | `toolbox build`, `toolbox check` |
| `toolbox/tool/get.dart`, `analyze.dart`, `test.dart`, `format.dart` | `workspace ...` |
| `toolbox/tool/dist.dart`, `device.dart` | `dist`, `device ...` |
| `toolbox/tool/emulator/emulator_mcp.dart` | The MCP server behind `emulator mcp`. |
| `platform/kernel/tool/build.dart`, `prepare.dart`, `bootimg.dart` | `os kernel ...` |
| `platform/rootfs/tool/build.dart`, `stage.dart`, `shell.dart`, `plan.dart`, `clean.dart`, `stage-plymouth.dart` | `os rootfs ...` |
| `platform/rootfs/tool/build-initramfs.dart`, `render-initramfs.dart`, `runtime_build.dart` | `os initramfs build`, `os initramfs render`, `os runtime build` |
| `platform/bluetooth/tool/build.dart` | `os bluetooth build` |
| `platform/splash/tool/*.dart` | `os splash ...` |
| `platform/diagnostics/tool/capture_a2dp.dart`, `analyze_tone.dart` | `diagnostics ...` |
| `packages/tempo_build/bin/tempo_build.dart` | Any route; the arguments are passed through. |

The other files in those directories are device programs, not entry points:
`platform/rootfs/tool/runtime.dart` is the source of `tempo-system`, and
`platform/bluetooth/tool/bootstrap.dart` is the modem bootstrap compiled for
the device.
