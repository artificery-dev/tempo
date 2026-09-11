# Toolchain container

The host contract for building Tempo is Dart, Git and Podman. Every other
compiler and build tool lives in one Podman image, `tempo-toolchain`, built
from `platform/toolchain/Containerfile`. The Dart build tooling in
`packages/tempo_build` decides, command by command, whether a step runs on the
host or inside that image, and it does so through one class, `Toolchain`. The
root filesystem is the exception: it needs loop mounts and a chroot, so it runs
in a rootful, privileged instance of the same image.

## Components

| Where | What |
| --- | --- |
| `platform/toolchain/Containerfile` | The image definition. |
| `.containerignore` | Limits the build context to `platform/toolchain/`. |
| `packages/tempo_build/lib/src/context.dart` | `Toolchain`, which builds the image and runs commands in it, and `FlutterSdk`, which finds pinned SDKs. |
| `packages/tempo_build/lib/src/process.dart` | `CommandRunner`, the process wrapper every command goes through, and `BuildFailure`. |
| `packages/tempo_build/lib/src/rootfs_container.dart` | `RootfsContainer`, the rootful path for rootfs work, and its prerequisite check. |
| `packages/tempo_build/bin/rootfs_container.dart` | The entry point compiled and run inside the rootful container. |
| `packages/tempo_build/lib/src/bootstrap.dart` | `toolbox dev bootstrap`, the firmware build order and the Git LFS client setup. |
| `packages/tempo_build/lib/src/bootstrap_sdk.dart` | Provisioning of the pinned Flutter SDKs under `build/sdks`. |
| `packages/tempo_build/lib/src/system_runtime.dart` | `toolbox dev os runtime build`, a typical mixed host and container build. |
| `config.yaml` `flutter:` and `daemon:` | The SDK, engine and embedder pins. |
| `toolbox/app/.fvmrc` | Toolbox's own Flutter pin. |

## What the image provides

The image starts from `debian:bookworm-slim`, the same release the device
runs. Its layers, in the order the Containerfile adds them:

| Layer | Contents |
| --- | --- |
| Kernel cross build | `gcc-arm-linux-gnueabihf`, `libc6-dev-armhf-cross`, `build-essential`, `bc`, `bison`, `flex`, OpenSSL and ncurses headers, `device-tree-compiler`, `kmod`, `cpio`, `rsync`, `python3`, gzip, xz and zstd, Git and curl. |
| flutter-pi cross build | armhf multiarch development packages for DRM, GBM, EGL, GLES, libinput, udev, xkbcommon, systemd, ALSA and GStreamer, plus `cmake` and `pkg-config`. Linking against bookworm's own armhf libraries gives the binary the sonames the rootfs ships. |
| Splash | `librsvg2-bin` for SVG rasterisation. |
| Root filesystem | `debootstrap`, `qemu-user-static`, `e2fsprogs`, `dosfstools`, `exfatprogs`, `parted`, `fdisk`, `fakeroot`, `uuid-runtime`. |
| Shell | `zsh`, `nodejs`, `unzip`, and Oh My Zsh configured system-wide in `/etc/zsh/zshrc`. |
| Rust | rustup with the `RUST_VERSION` toolchain, 1.92.0, the `armv7-unknown-linux-gnueabihf` and `wasm32-unknown-unknown` targets, `rustfmt` and `clippy`, under `/opt/rustup` and `/opt/cargo`. `wasm-bindgen-cli` 0.2.122 matches `packages/tempo_usb/rust/Cargo.lock`. |
| Test Dart | A standalone Dart SDK, `TOOLBOX_TEST_DART_VERSION` 3.12.2, at `/opt/toolbox-test` for the browser transport tests. It replaces neither Flutter pin. |
| Host native | `libasound2-dev` for the host-architecture daemon build and tests. |
| Linux Toolbox GUI | `clang`, `ninja-build`, GTK 3, `libmpv` and `libepoxy` headers. |
| Git LFS | `git-lfs` and `binfmt-support`, which bootstrap borrows rather than requiring on the host. |

The image also sets `TEMPO_TOOLCHAIN=1`, `ARCH=arm`,
`CROSS_COMPILE=arm-linux-gnueabihf-` and
`CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER=arm-linux-gnueabihf-gcc`,
so a kernel `make` or a `cargo build --target armv7-unknown-linux-gnueabihf`
needs no further arguments.

## Managing the image

```sh
toolbox dev toolchain build      # podman build -t tempo-toolchain
toolbox dev toolchain rebuild    # the same with --no-cache --pull
toolbox dev toolchain run CMD    # run one command in the container
toolbox dev toolchain shell      # zsh in the container
toolbox dev toolchain info       # image inspect, gcc, rustc and dtc versions
toolbox dev toolchain clean      # remove the image
```

`Toolchain.build` runs `podman build` with the checkout root as context and
the Containerfile passed by path; `.containerignore` keeps everything but
`platform/toolchain/` out of that context. Bootstrap builds the image once,
and any `Toolchain.run` that finds no `tempo-toolchain` image builds it first.

## How commands are dispatched

Every process the tooling starts goes through `CommandRunner`. `run` inherits
the terminal, forwards SIGINT and SIGTERM to the child, and turns a non-zero
exit into a `BuildFailure`; `capture` collects output instead. Arguments always
cross the process boundary as a list, never as a shell string.

`Toolchain.run` decides where a command executes:

- If `TEMPO_TOOLCHAIN` is set in the environment, the process is already
  inside the container and the command runs directly. This is what lets the
  same Dart code work when re-entered from within the image.
- Otherwise it runs `podman run --rm -i`, with `-t` when stdin is a terminal,
  bind-mounting the checkout at its real host path and working there, with
  `--userns=keep-id` so files come out owned by the developer. The Git
  metadata directory of a worktree is mounted read-only when it lives outside
  the checkout, so `git` inside the container still resolves. `CARGO_HOME` is
  pointed at `build/cargo`, keeping the registry cache with the rest of the
  build output. Callers add environment variables and extra read-only mounts
  as needed.

Which side each kind of work lands on:

| In the container | On the host |
| --- | --- |
| Kernel `make`, `fdtput`, `dtc` | Dart itself: `dart compile exe --target-os=linux --target-arch=arm` for `tempo-system`, the modem bootstrap and the daemon bundle |
| `arm-linux-gnueabihf-gcc` for `mmio.so`, `tempo-system.so`, the screenshot helper | The app's AOT snapshot, because the pinned `gen_snapshot` is a Linux x64 executable |
| `cargo` for the daemon native core, `tempo_kms` and `tempo_usb`; `wasm-bindgen` | Git, including submodule and LFS operations |
| flutter-pi's CMake build | SSH to the device |
| Flutter SDK validation and `precache`, the Linux Toolbox GUI build | `gen_init_cpio`, once the container has compiled it |
| `e2fsck` and the radio image check in `dist` | Podman itself |

`toolbox dev os runtime build` in `system_runtime.dart` shows the split in
one function: the host Dart compiles `platform/rootfs/tool/runtime.dart` to an
ARM executable, the container compiles `platform/rootfs/native/runtime.c` to
a shared library, and the host writes the manifest of both.

## Rootful Podman for the root filesystem

`toolbox dev os rootfs build`, `stage` and `shell` need to loop-mount an ext4
image, chroot into it and run armhf binaries under QEMU. Rootless Podman
cannot do that, so `RootfsContainer` runs the same image differently:

- The command is `sudo podman run`, or plain `podman` when already root, with
  `--privileged --user 0:0 --userns=host`.
- The checkout is mounted `rw,rprivate`, so the image mounts made inside
  never propagate to the host namespace.
- The environment carries `TEMPO_ROOTFS_HOST=1`, `TEMPO_ROOTFS_LOCK_HELD=1`,
  `TEMPO_TOOLCHAIN=1`, and `SUDO_UID` and `SUDO_GID`, which the build uses to
  chown the finished image and the Plymouth payload back to the developer.
- The program run is a helper compiled on the host from
  `packages/tempo_build/bin/rootfs_container.dart`, with the fully resolved
  configuration written as JSON into a temporary directory of mode `0700`.
  That helper refuses to run unless `TEMPO_ROOTFS_HOST=1`, so it is never
  mistaken for a user-facing command.

Rootless and rootful Podman keep separate image stores. Before each run,
`_ensureRootfulImage` compares the image ID in both and, when they differ,
does `podman save` and `sudo podman load` so the rootful side has exactly the
image a `toolchain rebuild` just produced.

`checkPrerequisites` runs during bootstrap and at the start of `toolbox dev
build`. In a disposable container it confirms the tools are present, creates
and loop-mounts a scratch ext4 image, executes the tracked ARM BusyBox through
`qemu-arm-static` in a chroot, registers the `qemu-arm` binfmt entry if child
execs do not already work, unmounts and runs `e2fsck`. The binfmt registration
is kernel state that a reboot clears, which is why the check repeats.

Before entering the container, `build` and `stage` first build the modem
bootstrap and the system runtime on the host side, since those need the host
Dart. The rootfs actions and distribution packaging share an exclusive lock on
the checkout, so two of them cannot open the image at once.

`TEMPO_ROOTFS_HOST=1` bypasses the container entirely. The command re-executes
itself under `sudo -E` on the host, which then needs debootstrap, QEMU and the
filesystem tools installed locally. `.env.example` lists it with the other
overrides. See [Root filesystem](rootfs.md) for what the build itself does.

## SDK pins

Three Flutter SDKs are pinned, for three different reasons:

| Pin | Where | Why |
| --- | --- | --- |
| Device app: `flutter.sdk_version`, 3.44.9 | `config.yaml` | flutter-pi loads a prebuilt `libflutter_engine.so` from `flutter.engine_binaries` at a fixed commit, and the AOT snapshot must come from the `gen_snapshot` of exactly that engine. `flutter.flutter_pi.commit` pins the embedder to match. Moving the SDK means moving the engine commit with it. |
| Daemon: `daemon.toolchain_version` 3.47.2, bundling `daemon.dart_version` 3.13.2 | `config.yaml` | `tempod` is plain Dart with no engine, so it uses a newer compiler. The Flutter SDK is only the delivery vehicle; `daemon build` checks that its bundled Dart reports the pinned version and fails otherwise. `TEMPO_DAEMON_DART` overrides the executable. |
| Toolbox: `flutter` | `toolbox/app/.fvmrc` | Toolbox is a desktop, web and mobile app with its own release cadence and follows its own pin. |

`bootstrapSdks` provisions all three under `build/sdks/flutter/<version>`.
`provisionFlutterSdk` copies an existing FVM checkout of that version when one
is found and is a plain Git checkout; otherwise it does a shallow fetch of the
tag, or the commit, from `github.com/flutter/flutter`. Each SDK is validated by
running `flutter --version` in the container with `HOME` and `PUB_CACHE` under
`build/bootstrap`, checking `bin/cache/flutter.version.json` against the pin
and confirming the bundled Dart exists. The app and Toolbox SDKs also get
`precache --linux`. Finally `.fvm/flutter_sdk` and `toolbox/app/.fvm/flutter_sdk`
are linked to the cache unless the developer already has something there.

`FlutterSdk.discover` is how every command finds an SDK afterwards. It tries
`TEMPO_FLUTTER_SDK`, then `build/sdks/flutter/<version>`, then the FVM cache
reported by `fvm api context`, then `~/fvm/versions/<version>`, and fails with
a pointer at bootstrap. A `.fvmrc` at the root that disagrees with
`flutter.sdk_version` produces a warning.

## Bootstrap

`toolbox dev bootstrap [--config FILE] [--build]` prepares a clean Linux x64
checkout. The steps, in order:

1. Take `build/bootstrap/lock`, import `--config` into `config.local.yaml`
   if that file does not exist, and check that a password or SSH key is set.
2. Confirm `git`, rootless `podman info` and `sudo podman info` work.
3. `git submodule update --init --recursive --depth 1`.
4. Build the toolchain image.
5. Copy the container's `git-lfs` into the Git common directory under
   `tempo/bin`, configure the LFS filters to use it, and pull
   `platform/firmware/**`, then verify no firmware file is still a pointer.
   The host's own Git transport and credentials are used; Podman never sees
   SSH keys.
6. Provision the SDKs and check the rootful rootfs prerequisites.
7. Resolve workspace dependencies, fetch the flutter-pi engine binaries and
   build the CLI to `build/toolbox/cli/toolbox`.

`--build` continues into `toolbox dev build`, which runs the firmware steps in
`firmwareBuildSteps` order and ends with `dist`.
