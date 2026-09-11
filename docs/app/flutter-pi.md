# flutter-pi and engine pairing

The player runs under flutter-pi, ardera's Flutter embedder for KMS and DRM,
rather than under a desktop shell. Tempo pins one commit of flutter-pi as a
submodule, applies a small patch set and one plugin of its own on top, and
cross compiles it against the same Debian armhf libraries the root filesystem
installs. flutter-pi loads a prebuilt `libflutter_engine.so` from ardera's
engine binaries repository, and the AOT snapshot the app ships must be
produced by the `gen_snapshot` of exactly that engine. The Flutter SDK, the
engine commit and the embedder commit are therefore one pin in three parts,
and `config.yaml` names all three together.

## Components

| Where | What |
| --- | --- |
| `config.yaml` `flutter:` | `sdk_version`, `engine_binaries`, `flutter_pi`, `pixel_format`, `install` paths and `vm_service_port`. |
| `.gitmodules`, `app/flutter-pi/flutter-pi` | The shallow flutter-pi submodule, marked `ignore = dirty` because the build patches it in place. |
| `app/flutter-pi/patches/*.patch` | Four patches applied over the pinned commit at build time. |
| `app/flutter-pi/plugins/plymouth_handoff.c` | Tempo's own embedder plugin, copied into the tree as `src/plugins/plymouth_handoff.c`. |
| `app/flutter-pi/tests/handoff_client_test.c` | A host-side test of that plugin against a fake `tempod`. |
| `app/flutter-pi/toolchain-armhf.cmake` | The CMake toolchain file for the cross build. |
| `app/flutter-pi/tool/engine.dart`, `build.dart`, `test.dart` | Wrappers over `toolbox dev app flutter-pi engine`, `build` and `test`. |
| `packages/tempo_build/lib/src/embedder.dart` | `embedderCommand`: fetches the engine, patches and builds flutter-pi, runs the native test. |
| `packages/tempo_build/lib/src/app.dart` | The AOT build and its engine version check. |
| `packages/tempo_build/lib/src/context.dart` | `FlutterSdk.discover`, which finds the pinned SDK. |
| `packages/tempo_build/lib/src/rootfs.dart` | Installs the embedder, engine, `icudtl.dat` and bundle into the image. |
| `packages/flutter_pi_plymouth_handoff/` | The Dart side of the hand-off plugin. |
| `platform/rootfs/native/runtime.c`, `platform/rootfs/overlay/etc/systemd/system/tempo.service` | How flutter-pi is launched on the device. |
| `packages/tempo_kms/` | `tempo-kms`, the Rust KMS crate the native device tools share. |
| `build/app/engine-binaries/`, `build/app/flutter-pi/` | The fetched engine and the built embedder. |

## The pins

| Key | Value | Meaning |
| --- | --- | --- |
| `flutter.sdk_version` | `3.44.9` | The Flutter SDK that builds the app. `.fvmrc` names the same version. |
| `flutter.engine_binaries.repo` | `https://github.com/ardera/flutter-engine-binaries-for-arm.git` | Where the prebuilt engine comes from. |
| `flutter.engine_binaries.commit` | `274423198d44945640bc0b0fcb4b27a164c804c9` | The engine build that matches the SDK. |
| `flutter.flutter_pi.repo` | `https://github.com/ardera/flutter-pi.git` | The embedder. |
| `flutter.flutter_pi.commit` | `f0b333052f4e71e51f9049e5016082357175057a` | The submodule commit the build insists on. |
| `flutter.pixel_format` | `RGB565` | The panel framebuffer format; the wrong one gives a garbled screen. |
| `flutter.install.flutter_pi` | `/usr/local/bin/flutter-pi` | Where the binary lands. |
| `flutter.install.engine_dir` | `/usr/lib` | Where `libflutter_engine.so.release` and `.debug` land. |
| `flutter.install.icudtl` | `/usr/share/flutter/icudtl.dat` | The ICU data file. |
| `flutter.install.bundle` | `/opt/tempo/flutter_assets` | The app bundle, with `app.so` inside it for a release build. |
| `flutter.vm_service_port` | `41200` | The debug build's Dart VM service port. |

`FlutterSdk.discover` looks for the pinned SDK at `TEMPO_FLUTTER_SDK`, then
`build/sdks/flutter/<version>`, then the fvm cache reported by `fvm api
context`, then `~/fvm/versions/<version>`. A candidate whose
`flutter.version.json` reports another framework version is skipped, and a
`.fvmrc` that disagrees with `config.yaml` produces a warning.

## Why the version cannot move freely

flutter-pi does not build the engine; it loads `libflutter_engine.so` at
runtime. The Dart framework in the app bundle, the engine and the
`gen_snapshot` that compiled the AOT snapshot all have to come from one
Flutter revision, or the snapshot's layout does not match the VM that loads
it. `toolbox dev app build --release` enforces this by comparing the SDK's
`bin/internal/engine.version` with `flutter.version` in the fetched engine
directory and refusing to compile when they differ. It also refuses to run
anywhere but Linux, because the pinned `gen_snapshot` for ARMv7 is a Linux
x64 executable.

The embedder is pinned for the same reason from the other side: it embeds a
copy of the Flutter embedder header and implements the platform contract the
engine expects. The comment on `flutter.sdk_version` records the specific
reason the pin sits at 3.44.9: Flutter 3.47's `WindowingOwnerLinux` asserts on
an `engineId` that flutter-pi does not provide.

Moving the SDK therefore means choosing an engine binaries commit built from
the same revision, a flutter-pi commit that runs against it, and checking
that the patch set still applies. The daemon is plain Dart with no engine and
uses a newer compiler on its own pin; see
[Toolchain](../platform/toolchain.md).

## Fetching the engine

`toolbox dev app flutter-pi engine` makes a sparse, blob-filtered clone of
the engine repository at the pinned commit into `build/app/engine-binaries`
and checks out seven files:

| File | Use |
| --- | --- |
| `arm/libflutter_engine.so.release` | The engine the release build loads. |
| `arm/libflutter_engine.so.debug` | The engine the JIT debug build loads. |
| `arm/icudtl.dat` | ICU data, installed system wide and copied into the bundle. |
| `arm/gen_snapshot_linux_x64_release` | The AOT compiler for the release build. |
| `arm/engine.version`, `arm/flutter.version`, `arm/dart-sdk.version` | The revisions the binaries were built from. |

The fetch is skipped when the directory already holds that commit and every
file is present and non-empty. It fails, and leaves nothing behind, if the
checked out `HEAD` is not the configured commit or any file is missing.
`bootstrap` runs this step and the embedder build after resolving the
workspace.

## Building the embedder

`toolbox dev app flutter-pi build` runs inside the toolchain container. It
refuses to start if the submodule is not initialised or its `HEAD` is not
`flutter.flutter_pi.commit`. It then applies every `patches/*.patch` in name
order with `git apply`, accepting a patch that is already applied and failing
on one that neither applies nor reverses cleanly. `plugins/plymouth_handoff.c`
is copied into `src/plugins/`, and CMake is configured with
`toolchain-armhf.cmake`:

| Option | Value |
| --- | --- |
| `CMAKE_BUILD_TYPE` | `Release` |
| `CMAKE_C_FLAGS` | `-DTEMPOD_SOCKET="<daemon.socket>"`, so the hand-off plugin knows the daemon socket. |
| `ENABLE_OPENGL` | on; `TRY_ENABLE_OPENGL` off, `ENABLE_VULKAN` off |
| `ENABLE_SESSION_SWITCHING` | off |
| `BUILD_TEXT_INPUT_PLUGIN`, `BUILD_RAW_KEYBOARD_PLUGIN` | on |
| `BUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN` | on, and required rather than tried |
| `BUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN`, `BUILD_TEST_PLUGIN`, `BUILD_SENTRY_PLUGIN` | off |

The toolchain file names `arm-linux-gnueabihf-gcc`, sets the multiarch
library architecture, and points `PKG_CONFIG_LIBDIR` at the armhf `.pc`
files so no host library leaks into the link. There is no sysroot: the
target headers and libraries sit at their real multiarch paths in the
container, which is what makes the binary ABI-exact for the device. The
result is `build/app/flutter-pi/flutter-pi`.

Because the patches dirty the checkout, `.gitmodules` marks the submodule
`ignore = dirty`, and `toolbox dev dist` records the submodule commit, a hash
of the tracked diff and the digests of untracked files in the build
provenance, alongside the same record for the kernel.

The other actions are `rev`, which prints the submodule's commit, `clean`,
which removes `build/app/flutter-pi`, and `test`, which compiles
`tests/handoff_client_test.c` against the plugin source and flutter-pi's
`platformchannel.c` and runs it. The test stubs the embedder calls the plugin
makes and talks to a fake `tempod` in a thread, so it covers the wire
protocol and the plugin's decisions rather than a real boot.

## The patches

| Patch | Change |
| --- | --- |
| `0001-platformchannel-json-integral-numbers.patch` | The JSON codec printed every number with `%g`, so keys whose xkb keysym is an XF86 code arrived as doubles and the framework's raw key parser threw. Integral values now print as integers. |
| `0002-plymouth-handoff-embedder.patch` | Adds `src/plugins/plymouth_handoff.c` to the build and exposes `flutterpi_get_drmdev` and `flutterpi_request_frame` for it. |
| `0003-video-playbin-audio.patch` | Builds the video pipeline on `playbin` with an `appsink` as its video sink instead of a video-only `uridecodebin`, which silently discarded audio; volume reaches `playbin`, and `TEMPO_VIDEO_STATS` logs caps and sink statistics. |
| `0004-video-share-planar-frame-upload.patch` | Exports a software I420 frame's single allocation once and shares it across planes instead of copying it three times into GBM buffers. |

## The hand-off plugin

`plymouth_handoff.c` registers the `flutter_pi/plymouth_handoff` method
channel. flutter-pi starts while plymouth still holds the DRM master, renders
its first frame and waits. When the Dart side calls `handoff` after the first
frame, the plugin sends `{"op":"drm-handoff"}` with the DRM fd attached over
`SCM_RIGHTS` to the `tempod` socket, and `tempod` fades the splash, drops
plymouth's master and sets master on the shared fd. Without a daemon it falls
back to doing the same in process, which works when flutter-pi runs as root.
The full sequence is in [Boot splash](../platform/splash.md).

## Install and launch

The rootfs build installs whichever of the embedder, the two engine variants
and `icudtl.dat` have been built, at the `flutter.install` paths, and copies
the bundle to `flutter.install.bundle` with `icudtl.dat` inside it.
`tempo.service` starts only when the binary and the bundle exist, after
`plymouth-start.service` and `tempod.service`, as the unprivileged `tempo`
user. `tempo-system launch` checks whether both volume keys are held and then
execs one of:

```sh
flutter-pi --release --pixelformat RGB565 /opt/tempo/flutter_assets
flutter-pi --pixelformat RGB565 /opt/tempo/flutter_assets \
  --vm-service-port=41200 --vm-service-host=0.0.0.0 --disable-service-auth-codes
```

The second is the JIT debug build, which `toolbox dev app attach` connects
to over the gadget link. `toolbox dev app deploy` ships a freshly built
bundle without rebuilding the image, refusing a bundle whose `app.so`
presence does not match the requested mode. See
[Working with a device](../development/device.md).

flutter-pi derives its device pixel ratio from the DRM connector's physical
size as `(10 * width) / (width_mm * 38)`, which for the Y2's panel is
`4800 / 1748`. `tempo_core` pins the same value in `Panel.devicePixelRatio`
rather than trusting the embedder, so the emulator reproduces the player
exactly; see [Interface](interface.md).

## tempo_kms

`packages/tempo_kms` is not part of flutter-pi, which does its own modesetting.
It is `tempo-kms`, a small Rust crate in the root Cargo workspace that the
native device tools share: open `/dev/dri/card0`, find the connected
connector, take its preferred mode, and find a CRTC through the connector's
current encoder or the device's first. It speaks DRM through the pure-Rust
`drm` crate with no libdrm at link time, and leaves buffers and presentation
to each tool. The display driver side is in
[Display](../porting/display.md).
