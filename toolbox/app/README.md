# Tempo Toolbox

The Flutter Toolbox combines the Y2 device installer and a mocked player emulator.
The emulator runs in its own window on desktop and an in-app route on Android/iOS.
Radio, power and device controls use mock data; compatible host media playback is
retained.

The GUI and standalone CLI use `packages/toolbox_core` and `packages/tempo_usb`.
The native Rust helper and browser Wasm share protocol, geometry, hashing and
readback policy. Device operations include inspection, full gzip backup,
`.y2-firmware` installation and native restore from gzip or validated legacy
zstd backup directories. BOOT1 is skipped unless explicitly enabled.

Toolbox imports native firmware packages and legacy scatter ROMs directly.
The firmware manifest schema lives in `packages/tempo_usb/firmware/`.

Build using `toolbox dev toolbox build web`,
`toolbox dev toolbox build native`, or `toolbox dev toolbox check` from a checkout.
For a source bootstrap, run `dart run bin/toolbox.dart dev toolbox build native`
in `toolbox/cli` using the Toolbox SDK pin.
The Toolbox has an independent SDK pin in `.fvmrc`; the device OS Flutter engine
pairing is not changed by Toolbox development. Build outputs live under root
`build/toolbox` and Flutter's application build directory.

A browser build requires the pinned wasm-bindgen CLI and serves over HTTPS or
localhost in Chromium. All authored connection, ZIP staging, browser storage
and gzip streaming policy is Dart; the small `web/installer.js` only loads the
generated Wasm ES module before Flutter. Firmware images are staged in origin
private storage and verified by Rust before requesting device access. Backups
require approximately 8 GB of temporary storage, or a direct file destination.
Native restore is intentionally unavailable in the browser.

Linux desktop builds and emulator startup have been tested. An Android
emulator-mode debug APK also builds. macOS, Windows, Android and iOS runtime
execution has not been verified here. Native mobile USB helper execution still requires platform
transport integration; the mock emulator does not require USB access.

Browser adapter and storage regression tests are Dart tests compiled for Node
in `packages/tempo_usb/test`. The actual Wasm bridge test expects generated
`web/pkg` assets from the web build. Rust fake-device tests cover guarded writes,
readback failures, archive validation, and restore geometry and sidecar hashes.
