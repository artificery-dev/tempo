# Wifi

The MT6582 carries its WiFi radio on the SoC, inside the connectivity
subsystem that also holds Bluetooth, FM and GPS. Tempo drives it with the
vendor full-MAC station driver ported into the kernel fork and brought onto the
current cfg80211 API, with the WMT stack managing power and firmware. Userland
is ordinary Debian: a `/dev/wmtWifi` write powers the function on,
`wpa_supplicant` owns association over nl80211, `systemd-networkd` supplies
addresses, and the settings UI reaches `wpa_cli` through `tempod`. Nothing on
the WiFi path starts until the modem bootstrap in
[Radio initialization](../platform/radio-initialization.md) has completed.

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/drivers/misc/mediatek-consys/plat/` | The `mediatek,mt6582-consys` platform driver, the CONSYS power sequence and the WMT auto-configuration. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/btif/` | The BTIF link between the AP and the CONSYS MCU. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/common/` | The WMT and STP cores, `wmt_dev.c` firmware loading, and `wmt_chrdev_wifi.c`, the `/dev/wmtWifi` node. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/wifi/mt6582/` | The full-MAC WLAN driver: management state machines, the NIC layer, the AHB HIF and the cfg80211 glue in `os/linux/`. |
| `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts` | The `consys`, `wifi` and `btif` nodes, the CONSYS rails and the reserved EMI window. |
| `platform/kernel/config/y2.config` | `CONFIG_MTK_CONSYS`, `CONFIG_MTK_CONSYS_WIFI`, cfg80211 and `CONFIG_EXTRA_FIRMWARE`. |
| `platform/firmware/mediatek/mt6582/` | `WIFI_RAM_CODE_MT6582`, `WMT_SOC.cfg` and the two WMT patch images. |
| `platform/rootfs/overlay/etc/systemd/system/mt6582-wifi-power.service` | Writes `1` to `/dev/wmtWifi` before `wpa_supplicant` and `0` on stop. |
| `platform/rootfs/overlay/etc/systemd/system/mt6582-wifi-power.service.d/10-calibration.conf` | `Requires=` and `After=tempo-modem-bootstrap.service`. |
| `packages/tempo_build/lib/src/rootfs.dart` | Writes the networkd and `wpa_supplicant` files and enables the units. |
| `config.yaml` | `networking.wifi.interface`, `firewall.trusted_interfaces` and `firewall.allow`. |
| `daemon/lib/src/services/host_radios.dart`, `radio_host.dart` | The `tempod` radio backend: `wpa_cli`, `networkctl` and the typed `/api/v1/radios` operations. |
| `packages/tempo_core/lib/src/settings/radio_screen.dart`, `services/radios.dart` | The Wi-Fi settings screens and the `RadioService` they read. |

## The CONSYS block

CONSYS is the MT6582's on-SoC connectivity subsystem. It has its own MCU, its
own power domain behind the SPM `CONN` MTCMOS, four MT6323 rails, and a window
of DRAM it reaches through an EMI remap register in infracfg. The AP talks to
the MCU over BTIF, a UART-like link at `0x1100c000` with two AP_DMA virtual
FIFO channels. WMT is MediaTek's management protocol over that link: it powers
the subsystem, downloads patches, and turns each function on and off. STP is
the transport framing beneath WMT that multiplexes the Bluetooth, FM and GPS
channels over the single BTIF link. WiFi is the exception: its control and
data use a dedicated AHB host interface at `0x180f0000`, and only its power and
firmware ownership go through WMT.

The board file declares three nodes for this. The `consys` node is the
platform glue, the `wifi@180f0000` node is the HIF with its interrupt on
GIC SPI 184, and the `btif` node is the link.

```dts
consys: connectivity@18070000 {
	compatible = "mediatek,mt6582-consys";
	reg = <0x10006000 0x1000>, <0x10001000 0x2000>, <0x10007000 0x100>,
	      <0x18070000 0x1000>, <0x180b0000 0x10000>;
	reg-names = "spm", "infracfg", "rgu", "conn-mcu", "conn-top";
	interrupts = <GIC_SPI 185 IRQ_TYPE_LEVEL_LOW>;
	interrupt-names = "bgf";
	clocks = <&infracfg CLK_INFRA_CONNMCU>;
	vcn18-supply = <&mt6323_vcn18_reg>;
	vcn28-supply = <&mt6323_vcn28_reg>;
	vcn33-bt-supply = <&mt6323_vcn33_bt_reg>;
	vcn33-wifi-supply = <&mt6323_vcn33_wifi_reg>;
	mediatek,pwrap = <&pwrap>;
	memory-region = <&consys_emi>;
	mediatek,co-clock;
};
```

The `btif` node at `0x1100c000` names the BTIF register block, the AP_DMA
block and their three interrupts, with the `CLK_PERI_BTIF` and
`CLK_PERI_AP_DMA` gates. `consys_res.c` never gates AP_DMA off again, because
the i2c controllers share it.

The EMI window is a `reserved-memory` node, `consys@bdf00000`, 1 MiB at the top
of DRAM with `no-map`. The remap register takes the address shifted right by
twenty bits, which is why the platform driver refuses a region that is smaller
than 1 MiB or not 1 MiB aligned. The MCU sees the window at `0xf0000000`; the
AP-side control block, print buffer and core dumps live at offset `0x80000`.

`mediatek,co-clock` mirrors `co_clock_flag=1` in `WMT_SOC.cfg`: the 26 MHz
reference comes from the AP, so the power sequence leaves VCN28 under software
control and off instead of switching it on as a crystal supply.

## Power sequence

`mtk_wcn_consys_hw.c` keeps the vendor order on mainline plumbing. The rails
go through the regulator framework and the LDO hardware-control bits, which the
regulator driver does not model, go through the pwrap regmap. On power on it
takes VCN18 out of low-power mode and enables it, sets VCN28 to software control
in co-clock mode, switches the `CONN` MTCMOS on through the SPM with the AXI
bus protection released in infracfg, enables the `CONNMCU` infra clock, and
polls the CONN MCU chip ID register until it reads `0x6582`. Power off reverses
the sequence. The per-function PA rails, VCN33_BT and VCN33_WIFI, are enabled
by the WMT core when that function turns on.

The platform driver probes at `subsys_initcall_sync`, before the WMT, STP and
BTIF initcalls, and `consys_wmt_autoconf()` maps the EMI window on demand if
the WMT core's own early attempt ran before the PMIC had probed.

## Firmware

All CONSYS firmware is compiled into the kernel. `y2.config` sets
`CONFIG_EXTRA_FIRMWARE_DIR` to `platform/firmware` and lists every file under
`CONFIG_EXTRA_FIRMWARE`, so `request_firmware()` is answered from the image and
the root filesystem carries nothing under `/lib/firmware` for the radios. The
WiFi-relevant pieces are these.

| File | Loaded by | Purpose |
| --- | --- | --- |
| `WMT_SOC.cfg` | `wmt_conf.c` through `wmt_dev_read_file()` | Antenna mode, GPS LNA settings and `co_clock_flag`. Parsed once at WMT start. |
| `mt6572_82_patch_e1_0_hdr.bin`, `mt6572_82_patch_e1_1_hdr.bin` | `consys_wmt_patch_search()` | The two-part ROM patch WMT downloads into the CONSYS MCU on the first function on. |
| `WIFI_RAM_CODE_MT6582` | `gl_kal.c` in the WLAN driver | The WiFi firmware, downloaded through the HIF when the WLAN function starts. |

The patch search replaces the Android `6620_launcher` directory scan. Bytes 22
and 23 of each patch file carry the firmware version, byte 24 carries the patch
count in its high nibble and this file's download sequence in its low nibble,
and bytes 25 to 27 are the load address the WMT partial-patch command carries.
`consys_wmt.c` builds the table from the two images, refuses an incomplete set,
and hands it to the WMT core when the SoC init script asks for `srh_patch`.
`consys_wmt_autoconf()` also does what the launcher's ioctls did before the
first function on: it sets the STP mode to BTIF full mode with FM over the
common interface and sends `WMT_OPID_HIF_CONF`.

`WMT_SOC.cfg` sets `coex_wmt_ant_mode=1`, which tells the coexistence firmware
that Bluetooth and WiFi share one antenna and the arbiter decides who
transmits. The `ant_mode` parameter of the WMT module overrides the file for
bring-up without a reflash.

## Powering the function on

`wmt_chrdev_wifi.c` registers the character device `/dev/wmtWifi` with major
153. Writing `1` calls `mtk_wcn_wmt_func_on(WMTDRV_TYPE_WIFI)`, which powers
the subsystem if it is off, downloads the ROM patch on the first use, enables
VCN33_WIFI, and then calls the WLAN driver's probe callback registered through
`mtk_wcn_wmt_wlan_reg()`. That probe initialises the AHB HIF, downloads
`WIFI_RAM_CODE_MT6582` in `INIT_CMD_ID_DOWNLOAD_BUF` sections, sends
`WIFI_START`, waits for the ready bit, and registers `wlan0` with cfg80211.
Writing `0` turns the function off through WMT. The node also accepts the
vendor's AP and P2P mode letters, which Tempo does not use.

On the rootfs this is `mt6582-wifi-power.service`, a oneshot with
`RemainAfterExit` that runs `printf 1 > /dev/wmtWifi` and `printf 0` on stop.
It carries `ConditionPathExists=/dev/wmtWifi`, so an image without the driver
skips it silently, and it is ordered `Before=wpa_supplicant-nl80211@wlan0.service`
so the interface exists when the supplicant starts. The drop-in adds
`Requires=` and `After=tempo-modem-bootstrap.service`: the radio hardware is
only in a usable state after the modem bootstrap has run, and the unit does not
start at all if that helper fails.

## The cfg80211 driver

The driver under `wifi/mt6582/` is the vendor gen2 WLAN driver for the
MT6628-class core, built with `CONFIG_MTK_CONSYS_WIFI`, with its Linux glue in
`os/linux/gl_init.c` and `gl_cfg80211.c` brought onto the current
`cfg80211_ops` signatures through small compatibility wrappers. `y2.config`
keeps `CONFIG_CFG80211_WEXT` because the driver still carries its Wireless
Extensions private ioctls, and leaves `mac80211` off, since the MAC runs in the
firmware.

The wiphy it registers advertises this.

| Property | Value |
| --- | --- |
| Interface modes | Station and ad-hoc. The wiphy is created as `NL80211_IFTYPE_STATION`. |
| Bands | 2.4 GHz only. The 5 GHz table exists in the source but is not registered. |
| Cipher suites | WEP40, WEP104, TKIP, CCMP and AES-CMAC. |
| Scan | One SSID per scan request, 512 bytes of extra IEs. |
| Signal | Reported in mBm. |
| Flags | `WIPHY_FLAG_SUPPORTS_FW_ROAM`. |
| Operations | Change interface type, add, delete and default keys, get station, scan, connect, disconnect, join and leave IBSS, power management, PMKSA set, delete and flush, and associate. |

Association is the firmware's, through `connect` and `disconnect`, which is
what `wpa_supplicant` uses with the nl80211 driver. The interface name is
`wlan0`.

## Userland

`rootfs.dart` writes two files for the interface named by
`networking.wifi.interface`.

| File | Contents |
| --- | --- |
| `/etc/systemd/network/25-wlan0.network` | `DHCP=yes`, `IPv6AcceptRA=yes`, DHCPv4 route metric 50. |
| `/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf` | `ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev` and `update_config=1`, mode `0600`. |

It enables `mt6582-wifi-power.service` and `wpa_supplicant-nl80211@wlan0.service`.
The supplicant starts with an empty network list, and `update_config=1` lets
`save_config` write the profiles the user adds back into the file. The USB
gadget link keeps its lower route metric, so a host on the cable stays the
default route while WiFi is up.

`config.yaml` also drives ufw. `firewall.trusted_interfaces` lists only `usb0`,
and `firewall.allow` is the port list for every other interface. With that list
empty nothing inbound is accepted over WiFi, and `ssh` over WiFi stays blocked
until `22/tcp` is added there. The build refuses a deny policy whose trusted
interface rule is missing.

The settings UI does not run commands itself. `RadioService` in
`packages/tempo_core` talks to `tempod` through `daemon_client`, and `RadioHost`
in the daemon validates each typed operation before `HostRadios` runs it as a
subprocess with a fixed locale, no inherited systemd variables and a forty
second bound. The operations map onto the tools like this.

| Operation | What `HostRadios` does |
| --- | --- |
| `refresh` | `wpa_cli status`, and with `scan` a `wpa_cli scan` followed by `scan_results` and `list_networks` three seconds later. |
| `wifi.enable` | `networkctl up` or `down` on the interface, then `wpa_cli reconnect`. The interface must be managed by networkd. |
| `wifi.join` | `add_network`, `set_network ssid` as hex, the PSK over stdin so it never appears in an argument list, `select_network`, up to fifteen seconds of polling for `wpa_state=COMPLETED`, then `networkctl renew` and `save_config`. A failed join removes the profile it created. |
| `wifi.disconnect` | `wpa_cli disconnect`. |
| `wifi.forget` | `remove_network` and `save_config`. |

The interface name comes from `TEMPO_WIFI_INTERFACE` or the first entry under
`/sys/class/net` with a `wireless` directory. Signal is reduced to three bars
at -55 and -70 dBm. `WifiNetwork.supported` excludes EAP, WEP and SAE-only
networks, so the UI offers `Connect` only for open and WPA-PSK networks.

`RadioScreen` shows the on and off toggle, `Scan again`, the `Saved Networks`
list and one row per network with its bars and security. Selecting a network
opens a screen with the password field, `Connect`, `Disconnect` and
`Forget Network`. The status bar icon follows `WifiReading`, which the service
refreshes every ten seconds while the app runs. In the emulator the service
uses a mock backend and never touches the host's networking.
