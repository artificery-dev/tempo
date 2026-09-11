# Testing and checks

Tempo's checks are spread over three languages and two SDK pins, and
`toolbox dev` gathers them into a few commands. `workspace analyze` and
`workspace test` walk every Dart root with the SDK each one is pinned to;
`daemon test`, `daemon check` and `toolbox check` add the Rust suites, the
browser tests and the Toolbox's own Flutter tests, running whatever needs a
compiler or Node inside the toolchain container. Nothing here needs a device.
This page lists what runs where, which suites exist, and which tests only
run when the host can support them.

## Components

| Where | What |
| --- | --- |
| `packages/tempo_build/lib/src/commands.dart` | `workspaceCommand`: the root discovery and the per-root `get`, `analyze`, `test` and `format`. |
| `packages/tempo_build/lib/src/daemon.dart`, `daemon_native.dart` | `daemon test` and the container `cargo` wrapper. |
| `packages/tempo_build/lib/src/test_runner.dart` | `runDaemonTests`: the isolated package configuration that maps the SQLite native asset. |
| `packages/tempo_build/lib/src/daemon_deploy.dart` | `daemon check`. |
| `packages/tempo_build/lib/src/toolbox.dart`, `toolbox_linux.dart` | `toolbox check`, the browser test runner and the container Flutter SDK for Linux. |
| `packages/tempo_build/lib/src/embedder.dart` | `app flutter-pi test`. |
| `platform/recovery/build.sh` | The recovery service, status and charge-policy tests, run as part of `os recovery build`. |
| `toolbox/tool/analyze.dart`, `test.dart`, `format.dart`, `get.dart`, `check.dart`; `daemon/tool/check.dart` | Entry points forwarding to the same routes. |
| `.env.example` | The `TEMPOD_TEST_*` variables that enable the gated daemon tests. |

## The workspace commands

```sh
toolbox dev workspace get
toolbox dev workspace analyze
toolbox dev workspace test
toolbox dev workspace format
```

The roots are `app`, `daemon`, every directory under `packages/` with a
`pubspec.yaml`, and `toolbox/app` and `toolbox/cli`, sorted by path. Each
root runs with the SDK it is pinned to:

| Root | SDK |
| --- | --- |
| `daemon` | `daemon.toolchain_version`, the Flutter SDK whose Dart is `daemon.dart_version`. |
| `toolbox/app` | The revision in `toolbox/app/.fvmrc`. |
| Everything else | `flutter.sdk_version`, the device SDK. |

A root whose pubspec declares `sdk: flutter` runs `flutter`; the others run
`dart`. `get` runs `flutter pub get` once at the repository root for the pub
workspace, then `pub get` in every root that does not resolve through it.
`analyze` passes `--no-pub` to Flutter roots. `test` skips roots without a
`test/` directory and hands `daemon` to `daemon test` instead of running
`dart test` there. `format` runs `dart format` over all roots at once with
the device SDK; the pinned SDKs differ, so format only the files a change
touched. Extra arguments go to the underlying command. Failures are collected
and reported together at the end rather than stopping at the first root.

The pub workspace itself is `app`, `assets`, `daemon`, `daemon_client`,
`flutter_pi_plymouth_handoff`, `player_api`, `tempo_core` and `tempo_logger`;
see [Repository layout](repository.md).

## The suites

| Directory | What it covers |
| --- | --- |
| `app/test` | The app shell, the Flutter player service, the daemon data-storage and card-maintenance clients, and an in-process daemon integration test that drives `FlutterPlayerService` through `PlayerServer` and an owner connection. |
| `daemon/test` | The player server, credentials, owner connection, settings, storage and radio hosts, the Bluetooth player, Cadence coordination, roots, relocation and the datastore mover, shutdown, the device monitor and the native process and control clients. |
| `packages/tempo_core/test` | The player UI: dock, menus, settings, playback, volume, output routing, wallpaper, library screens, time zones, sleep, power and the rest. |
| `packages/player_api/test` | The player events and snapshot contracts. |
| `packages/tempo_build/test` | The build tooling: bootstrap, kernel, rootfs, splash, recovery, distribution and installer manifests, the daemon deploy, the emulator command, help text and the disk layout. |
| `packages/toolbox_core/test` | The SSH transport, live device operations, app deployment, support diagnostics and the A2DP capture. |
| `packages/tempo_usb/test` | The native engine through a fake helper process, and the `browser_*` suites for the Wasm session, storage, transports and archive handling. |
| `packages/tempo_data/test`, `packages/tempo_logger/test` | Profiles and the logger. |
| `toolbox/app/test` | The Toolbox controller, firmware drop, walkthrough, live device view, and the emulator suites under `test/emulator/`. |

`daemon_client`, `flutter_pi_plymouth_handoff`, `assets` and `toolbox/cli`
have no `test/` directory and are skipped.

## The daemon

```sh
toolbox dev daemon test [package:test arguments]
toolbox dev daemon check
```

`daemon test` first runs `cargo test -p tempod` and `cargo build -p tempod
--lib` in the toolchain container, which requires Linux. It then compiles
`daemon/bin/tempod.dart` with `dart build cli` for the host architecture into
`build/os/daemon/test-runtime`, which is how the SQLite native asset is
produced, writes an isolated `package_config.json` and a `native_assets.yaml`
pointing `package:sqlite3` at that library, and runs `package:test` from
`daemon/` with that configuration. The workspace lock is left alone. If
`build/rust/debug/libtempod_native.so` exists it is exported as
`TEMPOD_TEST_NATIVE_LIBRARY`. Arguments are passed through, so
`toolbox dev daemon test test/player_server_test.dart` runs one file.

Three suites are gated on the environment:

| Variable | Test | Without it |
| --- | --- | --- |
| `TEMPOD_TEST_NATIVE_LIBRARY` | `native_control_test.dart` | Skipped. |
| `TEMPOD_TEST_NATIVE_EXECUTABLE` | `native_process_test.dart` | Skipped. |
| `TEMPOD_TEST_EXECUTABLE` | `host_process_test.dart` | Runs the daemon from Dart source instead of a compiled binary. |

`daemon check` runs `cargo fmt --all -- --check` and `cargo clippy -p tempod
--all-targets -- -D warnings` in the container, then `dart analyze` in
`daemon/` with the daemon SDK, and reports every failure together.

## Rust

The root Cargo workspace holds `daemon/native` and `packages/tempo_kms`, and
`packages/tempo_usb/rust` is a workspace of its own. `daemon test` runs the
`tempod` crate's tests. `toolbox check` runs `cargo fmt --check`, `cargo test
--locked` and `cargo clippy --all-targets --locked -- -D warnings` for the
USB engine, in the container on Linux and with the host `cargo` elsewhere,
since a Linux container cannot link a macOS or Windows USB executable. All
Rust output goes under `build/rust` or `build/toolbox/rust`. The
[Toolchain container](../platform/toolchain.md) page lists the pinned
`rustc`.

## The Toolbox and browser tests

```sh
toolbox dev toolbox check [flutter arguments]
```

After the Rust checks, `toolbox check` builds the Wasm engine and runs
`wasm-bindgen`, because the browser suites import the generated bindings from
`toolbox/app/web/pkg`. It then runs every `packages/tempo_usb/test/browser_*_test.dart`
with `dart test -p node` using the Dart SDK at `/opt/toolbox-test` inside the
container, with `PUB_CACHE` and `HOME` under `build/toolbox/`. Those files
carry `@TestOn('node')`, so a plain `dart test` on the host skips them.
Finally it runs `flutter analyze` and `flutter test` in `toolbox/app` and
`dart analyze` in `toolbox/cli`, on the host with the SDK pinned in
`toolbox/app/.fvmrc`. Only `toolbox build` for the Linux targets moves the
Flutter SDK into the container, under `build/toolbox/`, separate from editor
caches.

## The embedder

`toolbox dev app flutter-pi test` compiles
`app/flutter-pi/tests/handoff_client_test.c` against the flutter-pi sources
with the container's `gcc`, with `TEMPOD_SOCKET` set from `daemon.socket`,
and runs it. It needs `app flutter-pi build` to have produced `config.h`
first. See [flutter-pi and engine pairing](../app/flutter-pi.md).

## Recovery

`toolbox dev os recovery build` runs `platform/recovery/build.sh` in the
container, and that script compiles and runs `test-charge-policy.c` against
the kernel fork's charger policy header, then `test-status.py` and
`test-transfer.py`, before it builds the service, the display and the images.
A failing test fails the build. See [Tempo Recovery](../platform/recovery.md).

## What is host-only

| Condition | Effect |
| --- | --- |
| `FLUTTER_TEST` | `PlayerServices.device` opens no library, no player, no FM radio and no time zone service, and the emulator's `Rig` uses a memory filesystem and plays nothing. |
| Not Linux | `cargo` for the daemon core is refused; `daemon test`, `daemon check` and the wasm and browser steps need the container. |
| Windows | Tests that spawn POSIX fixtures or set Unix permissions are skipped in `toolbox_core`, `tempo_build` and `tempo_usb`. |
| No `TEMPOD_TEST_*` variable | The daemon's native library, native broker and compiled-binary suites are skipped or fall back as above. |
| No `web/pkg` bindings | The browser suites cannot import the Wasm module; `toolbox check` builds them first. |

The complete firmware build and the app's AOT snapshot are Linux x64 only;
see [Building](building.md).
