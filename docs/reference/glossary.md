# Glossary

Tempo's documentation names a MediaTek boot chain, a Debian system, a Flutter
player, a privileged daemon and a host-side installer, and each of those brings
its own vocabulary. This page defines the terms a newcomer meets across the
other pages, in one to three sentences each, and points at the page that
covers the term in depth. Entries are alphabetised under letter headings;
package and file names keep their spelling, so `tempo_core` sorts as a word.

## A

- **A2DP.** The Bluetooth audio streaming profile, and the only profile the player uses. A paired speaker or headset appears as a PipeWire sink, and the WirePlumber policy registers no HFP or HSP roles. See [Bluetooth](../porting/bluetooth.md).
- **AFE.** The MT6582's audio front end, the block that carries samples from DRAM to the I2S output feeding the DAC. The FM tuner's I2S also enters the AFE, which is why FM audio never passes through PipeWire. See [Audio](../porting/audio.md).
- **AOT snapshot.** `app.so`, the ahead-of-time compiled Dart code a release build ships beside the Flutter assets. It must come from the `gen_snapshot` of exactly the engine flutter-pi loads. See [flutter-pi and engine pairing](../app/flutter-pi.md).
- **API token.** The bearer credential that admits a controller to every `/api/v1` route of `tempod` except the owner endpoint. It is created on the device at first boot and never shipped in an image. See [tempod](../app/daemon.md).
- **applet.** One app on the dock, with its own navigator, focus scope and a small JSON memory, so switching away and back returns to the same screen. `Applet` and `AppletState` live in `tempo_core`. See [Interface](../app/interface.md).
- **APT32F.** The click wheel's controller. It reports the ring buttons as GPIO lines and wheel rotation as frames over I2C, which `apt32f-wheel.c` turns into key events. See [Input](../porting/input.md).
- **AVRCP.** The Bluetooth remote control profile. `tempod` registers an MPRIS player with BlueZ so a headset's buttons reach the playback owner and absolute volume is honoured. See [Radio hosting](../daemon/radios.md).
- **AW87559.** The Awinic class-D amplifier behind the DAC that drives the speaker, driven as an ASoC codec with its enable line on GPIO 8. See [Audio](../porting/audio.md).

## B

- **BlueZ.** The Linux Bluetooth stack. `bluetoothd` sees the CONSYS controller as `hci0`, and `tempod` drives pairing through `bluetoothctl` and `busctl`. See [Bluetooth](../porting/bluetooth.md).
- **BOOT1.** The first 4 MiB hardware boot region of the eMMC, holding the vendor preloader. Toolbox never writes it unless preloader flashing is enabled and acknowledged for one operation. See [Device operations](../toolbox/device-operations.md).
- **BOOT2.** The second 4 MiB hardware boot region. Backups read it and restores write it; an installation never touches it. See [Backups and going back to stock](../getting-started/backup-and-restore.md).
- **BOOTIMG.** The vendor partition LK loads the boot image from, at raw USER offset `0x2900000`. Tempo's `boot.img` goes there. See [Boot and flashing](../platform/boot-and-flashing.md).
- **BROM.** The boot ROM in the MT6582's silicon. It loads the preloader from BOOT1, and it is what answers over USB when a powered-off Y2 is plugged in. See [Boot and flashing](../platform/boot-and-flashing.md).
- **BTIF.** The UART-like link between the application processor and the CONSYS MCU. STP frames for Bluetooth, FM and GPS travel over it. See [Wifi](../porting/wifi.md).

## C

- **Cadence.** The media library project Tempo uses, developed separately at `git.artificery.dev/artificery/cadence`. Its daemon owns filesystem scanning, the SQLite database, jobs and artwork. See [Cadence integration](../app/cadence-integration.md).
- **cadenced.** Cadence's daemon. `tempod` starts it as the profile user, and the player talks to it over `/run/cadenced/media.sock`. See [Cadence supervision](../daemon/cadence.md).
- **cadence_client.** The Dart package through which the app, the daemon and `tempo_core` speak to `cadenced`. It is a git dependency on the public Cadence repository. See [Repository layout](../development/repository.md).
- **CID.** The card identification register of a microSD card, read from `/sys/class/block/mmcblk1/device/cid`. It is stable across reinsertion, so Cadence can tell a reinserted card from a different one. See [Storage](../porting/storage.md).
- **click wheel.** The Y2's capacitive ring with a centre button and four buttons on it. Every screen of the player is driven from it. See [Using the player](../getting-started/using-tempo.md).
- **config.local.yaml.** The gitignored overlay deep-merged over `config.yaml`, holding the device password and SSH keys. See [Configuration reference](configuration.md).
- **CONSYS.** The MT6582's on-chip connectivity subsystem: WiFi, Bluetooth, FM and GPS behind one MCU with its own power domain and EMI window. See [Wifi](../porting/wifi.md).
- **cover flow.** The dock's presentation of the apps as angled covers that turn past as the selection moves. Cover Flow in Settings turns them into flat pages. See [Using the player](../getting-started/using-tempo.md).
- **CS43131.** The Cirrus headphone DAC on the AFE's I2S output, with jack detection. See [Audio](../porting/audio.md).

## D

- **DA.** The download agent, a MediaTek program Toolbox loads into a powered-off player through the preloader. Tempo carries `DA.img` for legacy transfers and a Rockbox agent as the base of Tempo Recovery's RAM boot. See [Firmware inputs](../platform/firmware-inputs.md).
- **daemon_client.** The pure-Dart package of transports the app uses to reach `tempod`: the `Tempod` socket client and the HTTP and WebSocket clients. See [Architecture](../app/architecture.md).
- **datastore.** Cadence's metadata store, the `.cadence` directory under the home directory or the card root. It is separate from the media root. See [Cadence integration](../app/cadence-integration.md).
- **debug build key chord.** Holding both volume keys through boot makes `tempo-system launch` start the JIT build with the Dart VM service on port 41200. See [Boot and flashing](../platform/boot-and-flashing.md).
- **dock.** The row of icons along the bottom of the screen and the switcher between the apps behind them. Home, Apps, Library and Settings are always present. See [Interface](../app/interface.md).
- **DRM master.** The kernel's record of which open file may commit frames on a display. The splash handoff moves it from plymouth to flutter-pi. See [Boot splash](../platform/splash.md).
- **DSI.** MIPI Display Serial Interface, the two-lane link between the MT6582's display encoder and the panel. See [Display](../porting/display.md).
- **DTB.** The compiled device tree, `mt6582-innioasis-y2.dtb`, appended to the zImage inside `boot.img`. See [Kernel](../platform/kernel.md).

## E

- **EBR.** The vendor's extended boot records; see MBR and EBR.
- **EINT.** The MT6582's external interrupt block, register-identical to mainline `mtk-eint`, through which GPIO lines raise interrupts. See [Input](../porting/input.md).
- **EMI.** The external memory interface. The preloader's EMI table configures DRAM when a player is booted through the download agent, and CONSYS reaches a reserved 1 MiB EMI window at the top of DRAM. See [Wifi](../porting/wifi.md).
- **engine binaries.** The prebuilt `libflutter_engine.so`, `icudtl.dat` and `gen_snapshot` fetched from ardera's repository at a pinned commit. See [flutter-pi and engine pairing](../app/flutter-pi.md).
- **evdev.** The Linux input event interface. Every wheel notch, button and key ends up as an evdev key event that flutter-pi reads through libinput. See [Input](../porting/input.md).
- **exFAT.** The filesystem the Format SD Card action writes with `mkfs.exfat -L TEMPO`. The kernel also mounts FAT cards as a computer leaves them. See [Storage](../porting/storage.md).

## F

- **flutter-pi.** ardera's Flutter embedder for KMS and DRM, pinned as a submodule and patched. It runs the player on the panel without a desktop shell. See [flutter-pi and engine pairing](../app/flutter-pi.md).
- **FORCE_REINSTALL.** A flag file on the microSD card. When the initramfs finds it, it writes the rootfs image from the card onto `/dev/mmcblk0p1` before booting. See [Root filesystem](../platform/rootfs.md).

## G

- **GC9503V.** The GalaxyCore controller of the 480 by 360 panel, driven by `panel-gc9503v.c`. See [Display](../porting/display.md).
- **gen_snapshot.** The Dart AOT compiler shipped with the engine binaries as a Linux x64 executable, which is why release builds run only on Linux x64. See [Building](../development/building.md).
- **generation.** Cadence's attachment counter for a volume. Every path the player resolves is valid only for the current datastore ID and generation. See [Cadence integration](../app/cadence-integration.md).
- **Git LFS.** How the large vendor firmware blobs under `platform/firmware/` are stored. Bootstrap borrows the container's `git-lfs` to pull them. See [Firmware inputs](../platform/firmware-inputs.md).

## H

- **hci0.** The Bluetooth controller as BlueZ sees it, an `hci_dev` registered by `stp_hci.c` over the STP Bluetooth channel. See [Bluetooth](../porting/bluetooth.md).

## I

- **initramfs.** The small root filesystem packed into `boot.img`. Its `init` starts plymouth, installs a rootfs from the card when asked, and `switch_root`s into Debian. See [Root filesystem](../platform/rootfs.md).
- **Innioasis.** The maker of the Y2. See [The hardware](../getting-started/hardware.md).

## J

- **jog.** One detent of the wheel, the word that moves a list by a row. A fast spin becomes a page jog. See [Input](../porting/input.md).

## K

- **KMS.** Kernel mode setting, the DRM interface flutter-pi and `tempo-kms` use to find the panel and its mode. See [Display](../porting/display.md).

## L

- **Legacy Download Agent.** The Toolbox transfer method that uses the vendor agent alone without starting Tempo Recovery. It is slower, and it is the only method the browser build has. See [Backups and going back to stock](../getting-started/backup-and-restore.md).
- **libmpv.** The media player library the app drives through `media_kit` over `dart:ffi` for music. See [Playback](../app/playback.md).
- **lima.** Mesa's open driver for Mali Utgard GPUs, which renders the player on the Mali-400. See [Display](../porting/display.md).
- **LK.** Little Kernel, the vendor bootloader the preloader loads from the `UBOOT` partition. It loads Tempo's boot image and is never rebuilt or replaced. See [Boot and flashing](../platform/boot-and-flashing.md).
- **LOGO.** The vendor partition holding the MediaTek logo image. Block 0 is the power-on picture Tempo replaces; the charger blocks are kept byte for byte. See [Boot splash](../platform/splash.md).

## M

- **Mali-400.** The MT6582's Mali-400 MP2 GPU, powered through `mt6582-mfg-power` and used through lima. See [Display](../porting/display.md).
- **MBR and EBR.** The vendor's master and extended boot records, which sit `0xb80000` into the USER area and stay out of the kernel's view. Tempo's own MBR at sector zero is what makes the rootfs `/dev/mmcblk0p1`. See [Boot and flashing](../platform/boot-and-flashing.md).
- **MCP server.** The `toolbox dev emulator mcp` process that drives a running emulator over the Dart VM service, so a script or an agent can press buttons and read the screen. See [The emulator](../development/emulator.md).
- **media root.** The directory a Cadence datastore declares its media paths relative to: the home directory or the card mountpoint. See [Cadence integration](../app/cadence-integration.md).
- **modem bootstrap.** `tempo-modem-bootstrap.service`, which runs the stock modem firmware once at boot and powers it off again, because the modem's initialisation is what leaves the shared radio hardware usable. See [Radio initialization](../platform/radio-initialization.md).
- **mount ID.** The kernel's identifier for one mount in `/proc/self/mountinfo`. It changes on every mount, so eject and format carry it to be sure they act on the card the user saw. See [Storage](../porting/storage.md).
- **MPRIS.** The D-Bus media player interface. `BluetoothPlayer` publishes one at `/org/tempo/player` so BlueZ can offer AVRCP control. See [Radio hosting](../daemon/radios.md).
- **MSDC.** The MediaTek MMC host controller. MSDC0 drives the eMMC and MSDC1 the microSD slot. See [Storage](../porting/storage.md).
- **MT6323.** The MediaTek PMIC beside the MT6582. It owns the charger, the battery reading, the backlight current sinks, the regulators, the RTC, the power key and the final power cut. See [Power Management](../porting/power.md).
- **MT6582.** The MediaTek phone SoC in the Y2: four Cortex-A7 cores, a Mali-400 MP2 and the CONSYS radios. See [The hardware](../getting-started/hardware.md).
- **MT6627.** The FM tuner class inside CONSYS, reached over STP and exposed as `/dev/fm`. See [FM](../porting/fm.md).
- **mtkclient.** Community MediaTek tooling whose backup folder layout the Toolbox command line accepts for restore and backup resume. See [Backups and going back to stock](../getting-started/backup-and-restore.md).

## N

- **native broker.** `tempod-native`, the Rust half of `tempod`. It owns everything that needs root and a device file: the DRM handoff, backlight, mixer, FM, haptics, sounds and power, answered over the Unix socket. See [Native broker](../daemon/native-broker.md).

## O

- **OSD.** The on-screen notice layer: short cards for volume, output changes and a card coming or going, held in one slot by `Osd`. See [Playback](../app/playback.md).
- **overlay.** `platform/rootfs/overlay/`, the files copied verbatim onto the Debian image: units, drop-ins, a udev rule, PipeWire and WirePlumber configuration. See [Root filesystem](../platform/rootfs.md).
- **OVL.** The overlay engine at the head of the MT6582's display path, whose layer address register the screenshot tool reads. See [Display](../porting/display.md).
- **owner token.** The credential that admits exactly one frontend to `GET /api/v1/owner`, the playback owner WebSocket. See [Event protocol and HTTP transport](../daemon/protocol.md).

## P

- **panel.** The 480 by 360 screen as the app sees it. `Panel` fixes its size and pixel ratio, and `PanelSurface` lays the app out on exactly that canvas on the device and in the emulator. See [Interface](../app/interface.md).
- **PipeWire.** The sound server, running in the player user's own systemd session. libmpv, the wheel sounds and Bluetooth audio all go through it. See [Audio](../porting/audio.md).
- **playback owner.** The one client attached to `tempod`'s owner WebSocket that actually plays audio. Every other client sees playback through the daemon's `RemotePlayer` proxy. See [Event protocol and HTTP transport](../daemon/protocol.md).
- **player_api.** The pure-Dart package with the playback contract shared by the app and the daemon: `PlayerService`, `PlayerCommand`, `PlayerSnapshot` and the event envelopes. See [Architecture](../app/architecture.md).
- **PlayerServices.** The record of every service the UI may read, filled from `tempod` and the kernel on the device and from the rig in the emulator. See [Architecture](../app/architecture.md).
- **plymouth.** The boot splash daemon. The initramfs starts it before the rootfs is mounted, and it holds the panel until the app's first frame. See [Boot splash](../platform/splash.md).
- **PMIC.** Power management IC; on the Y2 the MT6323. See [Power Management](../porting/power.md).
- **preloader.** The first program the boot ROM loads from BOOT1. It is what keeps a powered-off Y2 reachable over USB, so Toolbox protects it above everything else. See [Installing Tempo](../getting-started/installing.md).
- **profile.** The data and config directories the player runs against, resolved by `tempo_data` at startup on the device or on the card. See [Storage and profiles](../app/storage.md).
- **pwrap.** The PMIC wrapper, the serial link through which the SoC reaches the MT6323's registers. See [Power Management](../porting/power.md).

## R

- **RAM boot pair.** `ramboot-DA.bin` and `payload.bin`, the patched download agent and the recovery kernel it loads into RAM. See [Tempo Recovery](../platform/recovery.md).
- **RDMA.** The read DMA engine between the OVL and the colour block in the display path. See [Display](../porting/display.md).
- **RDS.** Radio Data System, the FM sideband carrying the station name and text, drained one record per query. See [FM](../porting/fm.md).
- **readback verification.** Reading every written range back from the chip and comparing it with the source. It is on by default for every Toolbox write. See [Device operations](../toolbox/device-operations.md).
- **RECOVERY.** The vendor partition at raw USER offset `0x3900000`, where Tempo writes `recovery.img`, the same environment as Tempo Recovery. See [Tempo Recovery](../platform/recovery.md).
- **rig.** The emulator's mocked machine: battery, radios, card, backlight and output, set by hand. See [Emulator](../toolbox/emulator.md).
- **Rockbox.** A community firmware with a port for the Y2. Its download agent is the base of Tempo Recovery's RAM boot. See [Firmware inputs](../platform/firmware-inputs.md).
- **rootful Podman.** Podman run through `sudo`, needed for the rootfs build's loop mounts and chroot. Rootless Podman runs every other container step. See [Toolchain container](../platform/toolchain.md).
- **RPMB.** The eMMC's 512 KiB replay-protected region. Tempo never reads or writes it, and backups record it as zeros. See [The hardware](../getting-started/hardware.md).

## S

- **scatter file.** SP Flash Tool's text description of a ROM's partitions, with two addresses per row. The stock scatter is the source of every partition name and size. See [Boot and flashing](../platform/boot-and-flashing.md).
- **shade.** `ScreenShade`, the black the UI fades to when the screen sleeps, with `DimShade` under it. It sits above the navigator so sleep is not a route. See [Interface](../app/interface.md).
- **Skip matching data.** The resume option that reads each destination range first and writes only the ranges that differ. See [Installing Tempo](../getting-started/installing.md).
- **SPFT.** SP Flash Tool, MediaTek's vendor flashing tool. Tempo produces a scatter export it can consume, and Toolbox imports its ROMs directly. See [Firmware packages](../toolbox/firmware-packages.md).
- **splash handoff.** The sequence in which flutter-pi renders its first frame, asks `tempod` over the socket to take DRM master on its behalf, and plymouth retires. See [Boot splash](../platform/splash.md).
- **storage selector.** The `tempo_data` file at `~/.local/state/tempo/storage-selector.json` recording whether library data lives on the device or on the card. See [Storage and profiles](../app/storage.md).
- **STP.** MediaTek's transport framing under WMT, multiplexing the Bluetooth, FM and GPS channels over BTIF. See [Wifi](../porting/wifi.md).

## T

- **Tempo Recovery.** A small Linux environment that runs entirely from RAM and exposes the eMMC to Toolbox over a bulk USB service. It is the default transfer method on the desktop. See [Tempo Recovery](../platform/recovery.md).
- **tempo_build.** The Dart package that implements every `toolbox dev` command. See [Development setup](../development/setup.md).
- **tempo_core.** The package holding every screen, widget and service interface of the player, shared by the device app and the emulator. See [Architecture](../app/architecture.md).
- **tempo_data.** The package for profiles and storage management, including the storage selector and the datastore move transaction. See [Storage and profiles](../app/storage.md).
- **tempo_kms.** `tempo-kms`, a Rust crate that opens `/dev/dri/card0` and finds the panel, its mode and a CRTC for the native device tools. See [flutter-pi and engine pairing](../app/flutter-pi.md).
- **tempo_logger.** The package for structured logging on the device and on the host. See [Logging](../app/logging.md).
- **tempo_usb.** The Dart package around the `tempo-installer` Rust crate that produces every USB byte Toolbox exchanges with a Y2. See [USB engine](../toolbox/usb-engine.md).
- **tempo-usb.** The native helper executable built from that crate. Toolbox runs one per operation and reads its JSON events. See [USB engine](../toolbox/usb-engine.md).
- **tempo-system.** The device helper with the `launch`, `sdmount`, `clear-reinstall-flag`, `eject-sd` and `format-sd` subcommands. See [Root filesystem](../platform/rootfs.md).
- **TempoLayout.** The constants in `tempo_build` for Tempo's USER-area layout and the sector-zero partition table. See [Boot and flashing](../platform/boot-and-flashing.md).
- **tempod.** The privileged service on the device: a Dart host serving the authenticated HTTP and WebSocket API on `127.0.0.1:8765`, plus the native broker. See [tempod](../app/daemon.md).
- **tempod-native.** The native broker's binary and systemd unit, socket-activated on `/run/tempod/tempod.sock`. See [Native broker](../daemon/native-broker.md).
- **TEMPREC1.** The magic that opens every 48-byte frame of Tempo Recovery's bulk protocol. See [Tempo Recovery](../platform/recovery.md).
- **tomeui.** The widget toolkit `tempo_core` and Toolbox are built on. `tomeui_clickwheel` adds the wheel grammar and the wheel-driven list, grid and rail. See [Interface](../app/interface.md).
- **Toolbox.** The host side of Tempo: the installer, the emulator host and a set of device tools, as a desktop app, a browser app and the `toolbox` command line. See [Toolbox overview](../toolbox/overview.md).
- **toolbox dev.** The developer side of the Toolbox CLI, one area and one action per command. See [The `toolbox dev` command reference](../development/toolbox-dev.md).
- **toolbox_core.** The Dart package with the operation policy, the SSH transport and the firmware handling shared by the Toolbox GUI and CLI. See [Device operations](../toolbox/device-operations.md).
- **toolchain container.** `tempo-toolchain`, the Podman image holding every compiler and build tool so the host needs only Dart, Git and Podman. See [Toolchain container](../platform/toolchain.md).

## U

- **UiScale.** The `tempo_core` enum that fixes row heights, bar height, grid and type: `compact`, `regular` and `large`, chosen as Interface Size. `regular` is the default. See [Interface](../app/interface.md).
- **USB gadget link.** The CDC-ECM network the Y2 presents over its cable at `10.42.0.1`, with a DHCP server, so a host can ssh in with no setup. See [Connecting to the device](../getting-started/connecting.md).
- **USER area.** The eMMC's main region, `0x1d2000000` bytes, `/dev/mmcblk0` under Linux. It holds LK, the vendor tables, the boot, recovery and logo images and the rootfs. See [Storage](../porting/storage.md).

## V

- **VM service.** The Dart VM's debugging service. The debug build listens on port 41200 for `flutter attach`, and the emulator publishes its URL for the MCP server. See [Working with a device](../development/device.md).

## W

- **Wasm.** WebAssembly. The `tempo-installer` crate builds as a Wasm module for the browser Toolbox through `wasm-bindgen`. See [USB engine](../toolbox/usb-engine.md).
- **WebUSB.** The browser API the web Toolbox uses to reach a MediaTek boot device from desktop Chromium. See [Installing Tempo](../getting-started/installing.md).
- **wheel word.** What the wheel says: a detent, a press or a hold, as `WheelWord` in `tomeui_clickwheel`. Feedback sounds and haptics answer each word. See [Interface](../app/interface.md).
- **WirePlumber.** PipeWire's session manager. Its policy on the Y2 follows the headphone jack and keeps Bluetooth to A2DP. See [Audio](../porting/audio.md).
- **WMT.** MediaTek's wireless management protocol over BTIF. It powers CONSYS, downloads the ROM patch and turns each function on and off. See [Wifi](../porting/wifi.md).
- **workspace.** The pub workspace rooted at `pubspec.yaml`, whose members share one dependency resolution; also the `toolbox dev workspace` commands that walk every Dart root. See [Repository layout](../development/repository.md).
- **wpa_supplicant.** The WiFi association daemon, driven through `wpa_cli` by `tempod` on the settings UI's behalf. See [Wifi](../porting/wifi.md).

## Y

- **Y2.** The Innioasis Y2, the click-wheel music player Tempo runs on. See [The hardware](../getting-started/hardware.md).
- **.y2-firmware.** Toolbox's installer package: a ZIP whose first entry is a manifest mapping images onto eMMC byte ranges, with the size and SHA-256 of every image. See [Firmware packages](../toolbox/firmware-packages.md).

## Z

- **zImage.** The compressed kernel with the device tree appended, wrapped in a MediaTek header inside `boot.img`. See [Kernel](../platform/kernel.md).
