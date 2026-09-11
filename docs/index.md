# Tempo documentation

Tempo is a Linux based media player firmware for the Innioasis Y2. It replaces
the stock software with mainline Linux, a Debian userland and a Flutter
interface driven from the click wheel. The top-level [README](../README.md)
has the short version of the project; this page is the map of everything else.

Start with the section that matches what you came here to do:

- **You have a Y2 and want to run Tempo on it.** Read [Getting started](#getting-started)
  in order. It covers what the device is, how to take a full backup before you
  touch anything, how to install with Toolbox, and how to get around the player
  once it boots. You do not need to build anything.
- **You want to build the firmware or change the code.** Go to
  [Developing Tempo](#developing-tempo) for the toolchain, the build, the
  emulator and how to get code onto a device. Then pick the component you are
  changing: [the player app](#the-player-app), [the daemon](#the-daemon),
  [Toolbox](#toolbox) or [the platform](#platform).
- **You are bringing up the MT6582 or a similar player on your own.** The
  [Porting notes](#porting-notes) collect what we learned about the hardware,
  and the [Platform](#platform) pages describe how Tempo puts it together.
- **You are looking for a specific key, command or term.** The
  [Reference](#reference) section has the configuration keys, the `toolbox dev`
  command list and a glossary.

## Getting started

For people who want Tempo on their Y2.

- [The hardware](getting-started/hardware.md): the Y2, the MT6582, what Tempo
  uses and what it leaves alone.
- [Installing Tempo](getting-started/installing.md): Toolbox on a desktop or in
  a browser, Backup & Restore, choosing a `.y2-firmware`, what the preloader
  acknowledgement means.
- [Backups and going back to stock](getting-started/backup-and-restore.md):
  the full backup, restoring it, restoring a legacy scatter ROM, Tempo Recovery.
- [Using the player](getting-started/using-tempo.md): the wheel and button
  grammar, the dock, menus, Now Playing, scroll by letter, the OSD.
- [Settings](getting-started/settings.md): the settings tree as a user sees it,
  appearance and wallpaper, data storage and the SD card, radio, time zone.
- [Connecting to the device](getting-started/connecting.md): USB networking and
  ssh, WiFi, Bluetooth audio, the serial console, the debug build.

## Developing Tempo

For people building the firmware or working on the code.

- [Development setup](development/setup.md): Dart and Podman, `config.yaml` vs
  `config.local.yaml`, bootstrap, pinned SDKs, what runs in the container.
- [Repository layout](development/repository.md): components, the pub
  workspace, the Cargo workspaces, SDK pins and why they differ.
- [Building](development/building.md): `toolbox dev build`, component order,
  what lands in `build/` and `build/dist/`, rebuilding one piece.
- [The `toolbox dev` command reference](development/toolbox-dev.md): every
  area and command, one line each.
- [Working with a device](development/device.md): deploying the app and daemon,
  `flash-boot`, logs, the diagnostics tools, recovering a bad boot.
- [The emulator](development/emulator.md): running the player UI on a desktop,
  mocked services, driving it over the VM service and MCP, screenshots.
- [Testing and checks](development/testing.md): workspace analyze/test, per
  component suites, Rust tests, browser tests, what is host-only.
- [Releasing](development/releasing.md): versioning, building the distributable
  set, signing, the acceptance pass on hardware.

## The player app

The Flutter application that runs on the device and in the emulator.

- [Architecture](app/architecture.md): `app/`, `tempo_core`, `player_api`,
  `daemon_client`, the service interfaces the emulator mocks.
- [flutter-pi and engine pairing](app/flutter-pi.md): the pinned
  embedder, engine binaries and AOT snapshot, the `tempo_kms` display library,
  why the Flutter version cannot move freely.
- [Interface](app/interface.md): dock, menu tree, screens, UI scale, wheel
  input handling, the panel and shade, theming and wallpaper.
- [Settings system](app/settings.md): `SettingNode` trees, bindings,
  persistence in the profile, migration.
- [Playback](app/playback.md): libmpv over PipeWire, video, FM radio, output
  routing and Bluetooth, volume and the OSD.
- [Cadence integration](app/cadence-integration.md): the media
  library daemon, datastore locations, relocation, the eject contract.
- [Storage and profiles](app/storage.md): `tempo_data` profiles, XDG layout,
  internal vs SD data storage, eject and format flows.
- [Logging](app/logging.md): `tempo_logger` on device and host.

## The daemon

`tempod`, the privileged service host the player talks to.

- [tempod](app/daemon.md): what it owns, the socket, systemd units,
  the plymouth to flutter-pi handoff, credentials.
- [Event protocol and HTTP transport](daemon/protocol.md): the app to daemon
  events in `player_api`, the `/api/v1` surface, authentication.
- [Native broker](daemon/native-broker.md): the Rust core, its ABI, the
  child-process boundary, device observations (battery, card, mounts).
- [Radio hosting](daemon/radios.md): FM control, the Bluetooth playback
  adapter, host radio operations.
- [Cadence supervision](daemon/cadence.md): process supervision, root
  availability, relocation and the datastore mover.

## Toolbox

The installer and emulator host, as a desktop app, browser app and CLI.

- [Overview](toolbox/overview.md): GUI, CLI and web builds, supported
  platforms and their current state, the independent SDK pin.
- [Device operations](toolbox/device-operations.md): inspect, backup, restore,
  flash; readback verification; the BOOT1 and preloader policies.
- [Firmware packages](toolbox/firmware-packages.md): the `.y2-firmware`
  format, the manifest schema, legacy scatter ROM import.
- [USB engine](toolbox/usb-engine.md): `tempo_usb` in native Rust and Wasm,
  the recovery bulk transfer protocol, the Linux udev rule.
- [Emulator](toolbox/emulator.md): the device frame, mocked services, the
  window and route models on desktop and mobile.

## Platform

The operating system underneath the app.

- [Boot and flashing](platform/boot-and-flashing.md): the MediaTek
  boot chain, preloader, LK, the eMMC layout and the scatter offset shift,
  where Tempo writes and where it never does.
- [Kernel](platform/kernel.md): the Linux fork and branch, the submodule pin,
  the product config, the driver workflow.
- [Root filesystem](platform/rootfs.md): the Debian build, the overlay,
  users and groups, networking, firewall, the runtime services, initramfs.
- [Boot splash](platform/splash.md): the LOGO partition, the plymouth theme,
  holding the animation until first frame.
- [Tempo Recovery](platform/recovery.md): the RAM-booted transfer environment,
  packaging, service and display, entry paths.
- [Radio initialization](platform/radio-initialization.md): the
  modem firmware bootstrap that brings up the shared radio hardware.
- [Firmware inputs](platform/firmware-inputs.md): the stock ROM, the download
  agent, what is carried in Git LFS and what is never committed.
- [Toolchain container](platform/toolchain.md): the shared toolbox image,
  what runs inside it, and the rootful path for the rootfs.
- [Diagnostics](platform/diagnostics.md): on-device screenshot and probe tools.

## Porting notes

Hardware knowledge that would matter to anyone bringing up this SoC or a
similar player.

- [Display](porting/display.md): DSI panel, the RDMA/DSI drivers,
  the RGB565 framebuffer, Mali through lima.
- [Input](porting/input.md): the click wheel and buttons through libinput.
- [Audio](porting/audio.md): codec, PipeWire realtime setup, headphones as
  antenna.
- [Power Management](porting/power.md): battery gauge, charge policy,
  restart and power-off.
- [Storage](porting/storage.md): eMMC, the microSD slot, exFAT.
- [Wifi](porting/wifi.md): the CONSYS block, WMT and the EMI window, the
  full-MAC cfg80211 driver, power-on through `/dev/wmtWifi`, wpa_supplicant
  and the settings UI.
- [Bluetooth](porting/bluetooth.md): the hci driver over STP, the ROM patch,
  the modem bootstrap dependency, A2DP through PipeWire and WirePlumber,
  pairing and AVRCP control through tempod.
- [FM](porting/fm.md): the MT6627 tuner on CONSYS, `/dev/fm` and its ioctls,
  the I2S route into the AFE and why FM bypasses PipeWire, the headphone
  antenna, tempod's fm op and the tuner screen.

## Reference

- [Configuration reference](reference/configuration.md): every `config.yaml`
  key, `config.local.yaml`, `.env.example` and `.env.device.example`.
- [Glossary](reference/glossary.md): Y2, MT6582, CONSYS, LK, DA, SPFT,
  scatter, Cadence, tempod, and the rest.
