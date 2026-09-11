# Toolchain container

The host contract for building Tempo is Dart, Git and Podman. Every other
compiler and build tool lives in one published container image, the shared
toolbox at `git.artificery.dev/artificery/toolbox`, pinned by tag as
`toolchain.image` in `config.yaml`. The Dart build tooling in
`packages/tempo_build` decides, command by command, whether a step runs on the
host or inside that image, and it does so through one class, `Toolchain`. The
root filesystem is the exception: it needs loop mounts and a chroot, so it runs
in a rootful, privileged instance of the same image. CI runs every job in the
same image, from the same pin.

## Components

| Where | What |
| --- | --- |
| `config.yaml` `toolchain.image` | The image tag; `TEMPO_TOOLCHAIN_IMAGE` overrides it for one run. |
| `packages/tempo_build/lib/src/context.dart` | `Toolchain`, which pulls the image and runs commands in it, and `FlutterSdk`, which finds pinned SDKs. |
| `packages/tempo_build/lib/src/process.dart` | `CommandRunner`, the process wrapper every command goes through, and `BuildFailure`. |
| `packages/tempo_build/lib/src/rootfs_container.dart` | `RootfsContainer`, the rootful path for rootfs work, and its prerequisite check. |
| `packages/tempo_build/bin/rootfs_container.dart` | The entry point compiled and run inside the rootful container. |
| `packages/tempo_build/lib/src/bootstrap.dart` | `toolbox dev bootstrap`, the firmware build order and the Git LFS client setup. |
| `packages/tempo_build/lib/src/bootstrap_sdk.dart` | Provisioning of the pinned Flutter SDKs under `build/sdks`. |
| `packages/tempo_build/lib/src/system_runtime.dart` | `toolbox dev os runtime build`, a typical mixed host and container build. |
| `config.yaml` `flutter:` and `daemon:` | The SDK, engine and embedder pins. |
| `toolbox/app/.fvmrc` | Toolbox's own Flutter pin. |

## What the image provides

The image is built and published from its own repository,
`git.artificery.dev/artificery/toolbox`, whose README and `Containerfile`
are the reference for exactly what it carries and how to change it. It starts
from `debian:bookworm-slim`, the same release the device runs, so the armhf
cross toolchain links against the libc the rootfs ships. In outline:

| Contents | Where |
| --- | --- |
| gcc and g++ cross compilers for armhf, `build-essential`, `bc`, `bison`, `flex`, `dtc`, `kmod`, `cpio` | the kernel and Recovery builds |
| armhf multiarch development packages for DRM, GBM, EGL, GLES, libinput, udev, xkbcommon, systemd, ALSA and GStreamer, with `cmake` and `ninja` | the flutter-pi cross build |
| `debootstrap`, `qemu-user-static`, `e2fsprogs`, `parted` | the root filesystem |
| rustup with a pinned stable, `rustfmt`, `clippy`, the `armv7-unknown-linux-gnueabihf` and `wasm32-unknown-unknown` targets and `wasm-bindgen-cli` | the daemon core, `tempo_kms` and the USB engine |
| A standalone Dart SDK at `/opt/dart-sdk`, first on `PATH` | the build tool in CI and the browser transport tests |
| FVM with the current stable Flutter preinstalled | not used by Tempo, whose three pins are provisioned under `build/sdks` |
| Node, GTK 3, `libmpv`, `libepoxy`, `clang`, `git-lfs`, `zsh` | the Linux Toolbox GUI, the JavaScript actions in CI, the LFS bootstrap, the shell |

The image sets `TEMPO_TOOLCHAIN=1`, `ARCH=arm` and
`CROSS_COMPILE=arm-linux-gnueabihf-`, so a kernel `make` inside it needs no
further arguments, and `TOOLBOX_CONTAINER=1` for the toolbox's own tooling.

Moving to a new image is one line: change the tag in `config.yaml`. The
Recovery build stamp includes the tag, so Recovery is rebuilt with the new
compilers; CI's caches key on `config.yaml` too, so every job rebuilds once.

## Managing the image

```sh
toolbox dev toolchain pull       # podman pull of the pinned tag
toolbox dev toolchain run CMD    # run one command in the container
toolbox dev toolchain shell      # zsh in the container
toolbox dev toolchain info       # image inspect, gcc, rustc and dtc versions
toolbox dev toolchain clean      # remove the image from the local store
```

Bootstrap pulls the image once, and any `Toolchain.run` that finds the pinned
tag missing from the local store pulls it first. The registry is public, so
no login is needed to pull.

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
  the checkout, so `git` inside the container still resolves. `HOME` is
  `build/toolchain-home` and `CARGO_HOME` is `build/cargo`, keeping the
  shell, SDK and registry caches with the rest of the build output. Callers
  add environment variables and extra read-only mounts as needed.

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
image the developer's store pulled for the pinned tag.

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

1. Take `build/bootstrap/lock`.
2. Confirm `git`, rootless `podman info` and `sudo podman info` work.
3. `git submodule update --init --recursive --depth 1`.
4. Pull the toolchain image.
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
