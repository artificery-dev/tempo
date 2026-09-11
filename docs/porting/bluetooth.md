# Bluetooth

The MT6582's Bluetooth controller is part of the on-SoC connectivity
subsystem, reached over the BTIF link through MediaTek's WMT and STP protocol
stack. Tempo's kernel fork puts the STP Bluetooth channel behind an ordinary
`hci_dev`, so BlueZ sees `hci0` and nothing in userland knows the transport is
unusual. Above it the stack is standard Debian: `bluetoothd`, PipeWire with
its BlueZ plugin, and a WirePlumber policy that keeps the player to A2DP.
`tempod` brokers pairing and connection for the settings UI and publishes the
player over AVRCP, so a paired speaker or headphone controls playback and
volume. The controller only works after the modem bootstrap described in
[Radio initialization](../platform/radio-initialization.md) has run.

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/drivers/misc/mediatek-consys/bt/stp_hci.c` | The `hci_dev` over the STP Bluetooth channel. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/common/linux/pub/stp_chrdev_bt.c` | The vendor `/dev/stpbt` raw H4 node, kept for bring-up. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/plat/`, `btif/`, `common/` | The CONSYS platform glue, BTIF and the WMT and STP cores shared with WiFi and FM. |
| `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts` | The `consys` and `btif` nodes and the `vcn33_bt` rail. |
| `platform/kernel/config/y2.config` | `CONFIG_BT` with BR/EDR, LE and RFCOMM, `CONFIG_MTK_CONSYS_BT`, `CONFIG_MTK_CONSYS_BT_CHRDEV` and `CONFIG_EXTRA_FIRMWARE`. |
| `platform/firmware/mediatek/mt6582/mt6572_82_patch_e1_0_hdr.bin`, `_1_hdr.bin` | The two-part ROM patch WMT downloads into the CONSYS MCU. |
| `platform/rootfs/overlay/etc/systemd/system/bluetooth.service.d/10-calibration.conf` | `Requires=` and `After=tempo-modem-bootstrap.service`. |
| `platform/rootfs/overlay/etc/wireplumber/bluetooth.lua.d/51-tempo-a2dp.lua` | The A2DP-only WirePlumber policy. |
| `config.yaml` | The `bluetooth` package group: `bluez`, `libspa-0.2-bluetooth`, `bluez-tools`. |
| `daemon/lib/src/services/host_radios.dart`, `radio_host.dart` | `bluetoothctl` and `busctl` behind the typed `/api/v1/radios` operations. |
| `daemon/lib/src/services/bluetooth_player.dart` | The AVRCP player registered with BlueZ over D-Bus. |
| `daemon/native/src/output.rs` | The `output` op that lists BlueZ sinks and makes one the default. |
| `packages/tempo_core/lib/src/audio_route_dialog.dart`, `services/output.dart` | The switch prompt and the output service that raises it. |
| `packages/tempo_build/lib/src/diagnostics.dart`, `packages/toolbox_core` | `toolbox dev diagnostics capture-a2dp` and `analyze-tone`. |

## The BT block on CONSYS

Bluetooth, FM and GPS share one physical path to the CONSYS MCU: the BTIF
link at `0x1100c000`, a UART-like block with two AP_DMA virtual FIFO channels.
STP frames multiplex the three functions over it and WMT manages the
subsystem itself, so the Bluetooth driver never touches a register of its own.
The power domain, rails, EMI window and patch download are described in
[Wifi](wifi.md); the parts specific to Bluetooth are the `vcn33_bt` PA rail,
which WMT enables when the Bluetooth function turns on, and the STP Bluetooth
channel, `BT_TASK_INDX`.

`WMT_SOC.cfg` sets `coex_wmt_ant_mode=1`. Bluetooth and WiFi share one
antenna on this board and the coexistence firmware arbitrates between them.

## The hci driver

`stp_hci.c` is built with `CONFIG_MTK_CONSYS_BT` and registers one `hci_dev` at
`late_initcall`, after the CONSYS platform device and the WMT stack. The bus
type is `HCI_VIRTUAL`, since no enumerable bus fits an on-SoC link, and the
device's parent is the `consys` platform device. Its callbacks map onto the
STP API like this.

| Callback | What it does |
| --- | --- |
| `open` | Runs `consys_wmt_autoconf()`, then `mtk_wcn_wmt_func_on(WMTDRV_TYPE_BT)`, which powers CONSYS and downloads the patch on first use. Registers the STP receive callback and the WMT reset callback. |
| `close` | Unregisters both callbacks and calls `mtk_wcn_wmt_func_off(WMTDRV_TYPE_BT)`. |
| `send` | Prefixes the H4 packet-type byte and passes the whole frame to `mtk_wcn_stp_send_data()`, retrying every 2 ms for up to 50 tries while the STP transmit window is full. |
| receive | A work item drains `mtk_wcn_stp_receive_data()` into the kernel's `h4_recv_buf()` parser, which delivers ACL, SCO and event packets to the core. |
| `post_init` | Applies the packet-type and radio settings below once the core has finished its init sequence. |

A WMT reset notification marks the device as resetting, refuses sends until
the reset ends, and then calls `hci_reset_dev()` so BlueZ reopens the
controller.

`post_init` does three things. It sets `hdev->pkt_type` to exclude every EDR
ACL packet type and sets `HCI_QUIRK_FORCE_ACL_PTYPE`, so links run at Basic
Rate with all slot sizes. It sends three vendor commands, `0xfc79`, `0xfc7a`
and `0xfc93`, with fixed parameters matching the values the stock system
reads from NVRAM; these are the radio settings the controller needs before a
link. And it corrects the
LE command bitmap: the controller answers Read Local Supported Commands with
the LE bits clear although it runs LE scanning and connections, so the driver
sets the bits for LE Set Scan Enable, LE Create Connection, LE Connection
Update and LE Read Remote Used Features and re-sends the LE event mask. The
driver also sets `HCI_QUIRK_BROKEN_LOCAL_EXT_FEATURES_PAGE_2`, because the
firmware advertises two extended feature pages and then rejects the read of
page two.

Two module parameters exist for bring-up: `debug` dumps the H4 stream, and
`psm=0` disables STP power saving, which the stock system leaves on.

The vendor `/dev/stpbt` node is also built, behind
`CONFIG_MTK_CONSYS_BT_CHRDEV`, so the stock HCI sequence can be replayed by
hand. The STP Bluetooth channel has one consumer; `stp_hci_channel_busy()`
tells the char device when `hci0` holds it, and both must not be used at once.

`y2.config` enables `CONFIG_BT`, `CONFIG_BT_BREDR`, `CONFIG_BT_LE`,
`CONFIG_BT_RFCOMM` with its TTY, and the AES-CMAC and ECDH crypto that SMP
needs at power on. The UART and USB HCI transports, HIDP and BNEP stay off.

## Firmware

The only Bluetooth firmware is the CONSYS ROM patch, the two
`mt6572_82_patch_e1_*_hdr.bin` images built into the kernel through
`CONFIG_EXTRA_FIRMWARE`. WMT downloads it the first time any function turns
on after the subsystem powers up. `consys_wmt_patch_search()` in
`platform/kernel/linux/drivers/misc/mediatek-consys/plat/consys_wmt.c` builds
the download table from the images' headers; the format is described in
[Wifi](wifi.md). There is no separate Bluetooth firmware file and nothing is
read from the root filesystem.

## The radio initialization dependency

The controller's radio does not work from a cold boot with only the CONSYS
power sequence and the patch. The Y2's radio hardware is shared with the
cellular modem, and it is the modem firmware's own initialisation that leaves
the hardware in a state the Bluetooth firmware can use. Tempo runs that
firmware once at boot through `tempo-modem-bootstrap.service` and powers the
modem off again before `bluetoothd` starts.

`bluetooth.service.d/10-calibration.conf` therefore adds `Requires=` and
`After=tempo-modem-bootstrap.service`. `After=` alone would order the units
but let `bluetoothd` start over a failed bootstrap and expose a controller that
cannot hold a link; `Requires=` makes a failed bootstrap keep `bluetoothd`
down, so the fault is visible in the unit state instead of in a device that
pairs and then stalls. The WiFi power unit carries the same drop-in.

## A2DP through PipeWire

Audio reaches the controller through PipeWire, not through the kernel's SCO
path. `libspa-0.2-bluetooth` gives PipeWire its BlueZ plugin, and WirePlumber
runs `bluez_monitor` with the policy in `51-tempo-a2dp.lua`.

| Setting | Effect |
| --- | --- |
| `bluez5.headset-roles = "[ ]"` and `bluez5.hfphsp-backend = "none"` | No HFP or HSP is registered. The player has no telephony role, so no SCO link and no headset profile appear. |
| `bluez5.enable-hw-volume = true` | AVRCP absolute volume is used when the peer supports it. |
| `bluez5.auto-connect = "[ a2dp_sink ]"` on every `bluez_card.*` | A paired device connects its A2DP sink profile as soon as BlueZ reports it. |
| `bluez5.hw-volume = "[ a2dp_sink a2dp_source ]"` | Hardware volume applies to both A2DP directions. |
| `device.profile = "a2dp-sink"` | The card starts on the A2DP sink profile. |

PipeWire and WirePlumber run in the default user's own systemd instance, so a
connected speaker appears as an `Audio/Sink` node with `device.api` set to
`bluez5` in the same graph as the CS43131 DAC. The `pipewire.conf.d`
minimum quantum of 512 frames in the overlay applies to Bluetooth streams as
well; see [Audio](audio.md).

## Pairing and control from the UI

The Bluetooth settings screen is `RadioScreen` with `bluetooth: true`. It
reads `RadioService`, which polls `tempod` every ten seconds and sends the
typed operations `RadioHost` validates. `HostRadios` runs the tools as
subprocesses with a fixed locale and a forty second bound.

| Operation | What `HostRadios` does |
| --- | --- |
| `refresh` | `bluetoothctl show` for the powered state. With `scan`, an interactive `bluetoothctl` session sets `transport bredr` and a UUID filter for the A2DP sink service, scans for five seconds and exits; a one-shot `scan on` would drop its filter with the process. Then `devices` and `info` per device, keeping only those that advertise the A2DP sink UUID. |
| `bluetooth.enable` | `bluetoothctl power on` or `off`. |
| `bluetooth.connect` | `bluetoothctl --agent NoInputNoOutput pair` when the device is not yet paired, then `busctl call org.bluez ... org.bluez.Device1 ConnectProfile` with the A2DP sink UUID, so only that profile is connected. |
| `bluetooth.disconnect` | `bluetoothctl disconnect`. |
| `bluetooth.forget` | `bluetoothctl remove`. |

The device screen offers `Pair & Connect` or `Disconnect`, and `Forget Device`.
The status icon follows `BluetoothReading`, which reports `connected` when any
listed device has an active link.

Switching the output is separate from pairing. `DeviceOutput` in
`packages/tempo_core` asks `tempod`'s `output` op twice a second while a
listener exists. The reply lists the `bluez5` sinks in the graph, and the
first appearance of a new sink after the baseline snapshot is an arrival.
`TempoApp` treats a crossing between local audio and Bluetooth as a routing
decision: with the `onNewDevice` setting at `ask` it turns the screen on and
shows `AudioRouteDialog`, a wheel-captured dialog with `Switch` and
`Keep Current`; `ignore` does nothing; `switch`, the default, switches at once.
Accepting calls `select`, and `output.rs` sets `default.configured.audio.sink`
through `pw-metadata` to that node and pins it. When a pinned sink vanishes
the op pins whatever sink PipeWire fell back to, so a later arrival cannot
steal the default under `ask` or `ignore`. Jack
changes between the speaker and headphones never raise the dialog; WirePlumber
handles those from the DAC's own jack detect.

Playback control runs the other way, through `tempod --bluetooth-player`.
`BluetoothPlayer` registers `/org/tempo/player` with `org.bluez.Media1`
`RegisterPlayer` on `hci0`, implementing the MPRIS `Player` interface with
the current title, artist, album, length, position and the `Can*` flags from
the playback owner. Without a registered player BlueZ reports Stopped over
AVRCP and some peers acknowledge volume changes without applying them. The
peer's Play, Pause, PlayPause, Stop, Next and Previous arrive as D-Bus method
calls and become player commands. Registration retries every three seconds and
repeats when `org.bluez` changes owner. After the status becomes Playing the
daemon waits 1.5 seconds before signalling `bluetoothPlaybackReady`, which is
when the volume service is allowed to flush a Bluetooth adjustment it deferred
while the peer might still be restoring its own level.

## Diagnostics

`toolbox dev diagnostics capture-a2dp` records what the Y2 sends over A2DP.
The host pairs with the Y2 as an A2DP sink, and `A2dpCapture` creates a silent
`bt_diag` sink in the host's PipeWire, routes only the Y2's streams to it and
records the sink monitor as 48 kHz stereo 16-bit WAV with a `.meta` file of
timestamps, peer and format. `analyze-tone` then measures a captured steady
tone for dropouts, excluding leading and trailing silence, and exits with 0
for a continuous tone, 2 for gaps and 1 for no tone. Together they measure
link continuity from the controller through the peer, independent of the
player. The commands, defaults and options are in
[Diagnostics](../platform/diagnostics.md).
