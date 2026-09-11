# Development setup

Tempo is built and driven from one command-line tool, `toolbox dev`, whose
implementation lives in the `tempo_build` Dart package. The host needs only
Dart, Git and Podman: every cross compiler, kernel tool and Rust toolchain
lives in the `tempo-toolchain` container, and the pinned Flutter SDKs are
provisioned into the checkout. Machine-specific settings and credentials go
in a gitignored `config.local.yaml` that is merged over the tracked
`config.yaml`. The complete firmware build runs on Linux x64; the emulator
and most package checks run wherever the pinned Flutter SDKs run.

## Components

| Where | What |
| --- | --- |
| `config.yaml` | The tracked workspace configuration every build reads. No secrets. |
| `config.local.yaml` | Gitignored, deep-merged over `config.yaml`; holds the device password and SSH keys. |
| `config.local.example.yaml` | The template for `config.local.yaml`. |
| `.env.example` | The environment variables the build and dev CLI honour, with their defaults. |
| `.env.device.example` | The environment variables the player and daemon services honour on the device. |
| `toolbox/cli/bin/toolbox.dart` | The CLI entry point; `toolbox dev` hands off to `tempo_build`. |
| `packages/tempo_build/lib/src/commands.dart` | `runDeveloperCommand`, the `toolbox dev` dispatcher, plus `config` and `secrets`. |
| `packages/tempo_build/lib/src/bootstrap.dart` | `toolbox dev bootstrap` and the firmware build order. |
| `packages/tempo_build/lib/src/bootstrap_sdk.dart` | Provisioning of the pinned Flutter SDKs under `build/sdks/flutter/`. |
| `packages/tempo_build/lib/src/context.dart` | `Repository`, `BuildConfig`, `FlutterSdk.discover` and `Toolchain`. |
| `platform/toolchain/Containerfile` | The container image; see [Toolchain container](../platform/toolchain.md). |
| `build/toolbox/cli/toolbox` | The compiled CLI that bootstrap produces. |

## Host requirements

The host tooling contract is Dart, Git and Podman. Rootless Podman runs the
ordinary container steps, and rootful Podman through `sudo` runs the root
filesystem build. Bootstrap checks all three up front by running
`git --version`, `podman info` and `sudo podman info`, so a sudo prompt during
bootstrap is expected. Anything else, including the ARM cross compilers,
Rust, CMake, debootstrap and QEMU, is inside the image and never installed on
the host. Bootstrap also copies the container's `git-lfs` client into the Git
common directory and configures the LFS filters to use it, so the host does
not need Git LFS installed either.

`toolbox dev bootstrap` and `toolbox dev build` refuse to run unless the host
is Linux on x86_64. Two steps force that: the pinned `gen_snapshot` that
produces the app's ARM AOT snapshot is a Linux x64 executable, and the rootfs
build needs rootful Podman with loop mounts and a chroot. Individual commands
such as `emulator run`, `workspace analyze` and `daemon build --target host`
have no such requirement; `daemon build --target host` and `daemon check` do
need Linux, because the native core builds in the container.

## Configuration files

`BuildConfig.load` reads `config.yaml`, then deep-merges `config.local.yaml`
over it when that file exists. Maps merge key by key and any other value in
the local file replaces the tracked one, so a local file only needs the keys
it changes. `config.yaml` is public and carries no credentials; a rootfs build
with neither `user.password` nor `user.ssh_keys` configured fails rather than
shipping a guessable account.

```sh
cp config.local.example.yaml config.local.yaml
```

```yaml
user:
  password: change-me
  ssh_keys:
    - "{{ file(~/.ssh/id_ed25519.pub) }}"
```

Each `user.ssh_keys` entry is a public key, a path to a file of keys, or a
`{{ file(...) }}` reference. `~/` resolves against `TEMPO_CONFIG_HOME`, then
`HOME`. The example password `change-me` is rejected by the firmware input
check, so replace it or leave the password unset and rely on keys. A
plaintext password is hashed with `openssl passwd -6` before it reaches the
image; `toolbox dev secrets hash` does that in place and sets the file to
mode `0600`.

```sh
toolbox dev config json                # the merged configuration, password redacted
toolbox dev config get flutter.sdk_version
toolbox dev config has user.ssh_keys   # exit 0 when present and non-empty
toolbox dev secrets status             # presence of the local file, password and keys
```

The full key list is in the [Configuration reference](../reference/configuration.md).

## Environment overrides

The tooling reads a small set of environment variables from the process
environment. `.env.example` documents them with their defaults; `.env*` files
are gitignored, so the file is a place to keep exports, not something the CLI
loads by itself. The ones that matter during setup:

| Variable | Effect |
| --- | --- |
| `TEMPO_REPO` | The checkout to operate on, when not discoverable from the working directory. `--repo PATH` does the same per invocation. |
| `TEMPO_FLUTTER_SDK` | An explicit Flutter SDK, tried before the checkout cache and any FVM cache. |
| `TEMPO_DAEMON_DART` | The Dart executable for daemon builds; it must report `daemon.dart_version`. |
| `TEMPO_CONFIG_HOME` | The base for `~/` paths in `config.local.yaml`. |
| `TEMPO_DEVICE_HOST`, `TEMPO_DEVICE_USER`, `TEMPO_SSH_OPTS` | Where `toolbox dev device` connects; the defaults come from `networking.usb_gadget.address` and `user.name`. |
| `TEMPO_ROOTFS_HOST=1` | Build the rootfs on the host under `sudo` instead of in the container. |

`.env.device.example` lists the variables the player and daemon read on the
device, such as `TEMPOD_API_URL`, `TEMPOD_PROFILE_HOME` and `TEMPOD_SOCKET`.
They are service configuration, not build inputs; see
[tempod](../app/daemon.md).

## Bootstrap

From a clean checkout the compiled CLI does not exist yet, so the first run
uses `dart run` from the CLI package directory:

```sh
cd toolbox/cli
dart run bin/toolbox.dart dev bootstrap --config /absolute/path/to/config.local.yaml
cd ../..
build/toolbox/cli/toolbox dev build
```

`--config` copies the given file to `config.local.yaml` with mode `0600` when
no local file exists. If one exists and differs, bootstrap stops and asks you
to merge by hand; it never overwrites machine configuration. Bootstrap then
takes `build/bootstrap/lock`, validates the credentials, checks Git and both
Podman modes, initialises the submodules shallowly, builds the toolchain
image, pulls the Git LFS firmware under `platform/firmware/`, provisions the
three pinned Flutter SDKs, checks the rootful rootfs prerequisites, resolves
the workspace dependencies, fetches the flutter-pi engine binaries and
compiles the CLI to `build/toolbox/cli/toolbox`. `--build` continues straight
into `toolbox dev build`. The step order and the SDK provisioning are
described in detail in [Toolchain container](../platform/toolchain.md).

Bootstrap is safe to rerun after a failed prerequisite. SDKs already under
`build/sdks/flutter/<version>` are validated and reused, the LFS pull only
fetches what is missing, and the engine fetch is skipped when the checkout
already matches the pinned commit.

## The pinned SDKs

Three Flutter SDKs are pinned, each for its own reason: the device app's
`flutter.sdk_version` in `config.yaml`, which must match the prebuilt engine
that flutter-pi loads; the daemon's `daemon.toolchain_version`, whose bundled
Dart must report `daemon.dart_version`; and Toolbox's own pin in
`toolbox/app/.fvmrc`. Bootstrap installs all three under
`build/sdks/flutter/<version>` and links `.fvm/flutter_sdk` and
`toolbox/app/.fvm/flutter_sdk` to them unless something is already there.
FVM is not required, but an existing FVM checkout of a pinned version is
copied rather than downloaded again. `FlutterSdk.discover` finds an SDK by
trying `TEMPO_FLUTTER_SDK`, the checkout cache, the FVM cache reported by
`fvm api context`, then `~/fvm/versions/<version>`. See
[Repository layout](repository.md) for why the pins differ and
[Toolchain container](../platform/toolchain.md) for the provisioning steps.

## What runs where

`Toolchain.run` decides for each command whether it runs on the host or in
`podman run` with the checkout bind-mounted at its real path. Dart, Git, SSH
and Podman itself run on the host; compilers, `cargo`, CMake, kernel `make`,
Flutter SDK validation and the Linux Toolbox GUI build run in the container.
Inside the container `TEMPO_TOOLCHAIN=1` is set, so the same Dart code that
re-enters from within the image runs commands directly. The rootfs build is
the exception and uses a rootful, privileged instance of the same image.
[Toolchain container](../platform/toolchain.md) has the full split and the
image contents.

```sh
toolbox dev toolchain shell     # zsh inside the image, checkout mounted
toolbox dev toolchain info      # image inspect, gcc, rustc and dtc versions
```

## Working without the compiled CLI

Every `toolbox dev` route is also reachable through `dart run` in the pub
workspace, since `tempo_build` is a dev dependency of the root `pubspec.yaml`
and the component `tool/*.dart` files forward to the same dispatcher. From the
checkout root, `dart run app/tool/build.dart --release` is `toolbox dev app
build --release`, and `dart run packages/tempo_build/bin/tempo_build.dart os
kernel build` is `toolbox dev os kernel build`. The full command list is in
[The toolbox dev command reference](toolbox-dev.md).
