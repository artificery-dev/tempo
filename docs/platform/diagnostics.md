# Diagnostics

Tempo keeps a small set of tools for looking at a running Y2 without a serial
console: a display capture that reads the scanout buffer straight from the
display controller, a probe collection that gathers kernel and systemd state
over SSH, and two host-side audio tools for checking Bluetooth playback. The
device-facing ones hang off `toolbox dev device`; the host-only ones are
`toolbox dev diagnostics`.

## Components

| Where | What |
| --- | --- |
| `platform/diagnostics/device-screenshot.c` | The read-only framebuffer capture, cross-compiled on demand. |
| `platform/diagnostics/tool/capture_a2dp.dart`, `analyze_tone.dart` | Entry points forwarding to `toolbox dev diagnostics`. |
| `platform/diagnostics/README.md` | Usage notes for the audio tools. |
| `packages/tempo_build/lib/src/device.dart` | `toolbox dev device`, including `screenshot` and `collect-sysinfo`. |
| `packages/tempo_build/lib/src/device_diagnostics.dart` | The probe command table, `collectSysinfo`, and the Plymouth harvest and install used by the splash. |
| `packages/tempo_build/lib/src/diagnostics.dart` | `toolbox dev diagnostics capture-a2dp` and `analyze-tone`. |
| `packages/toolbox_core` | `A2dpCapture` and the tone analyser the diagnostics commands call. |

All device commands connect over SSH to the address in
`networking.usb_gadget.address`, or `TEMPO_DEVICE_HOST`, as `user.name`, or
`TEMPO_DEVICE_USER`. `toolbox dev device status` is the quick check that the
link works before running anything else.

## Screenshot

```sh
toolbox dev device screenshot [NAME]
```

The capture avoids DRM entirely and reads what the panel is showing. On the
host, `device-screenshot.c` is compiled statically with the toolchain
container's `arm-linux-gnueabihf-gcc` into `build/toolbox/device/device-screenshot`,
and recompiled whenever the source is newer. The helper is uploaded to
`/tmp`, its SHA-256 is checked on the device, and it runs as root. It then:

1. Reads `/proc/device-tree/compatible` and refuses to run unless both
   `innioasis,y2` and `mediatek,mt6582` are present.
2. Maps the OVL register page at `0x14007000` through `/dev/mem` and reads the
   layer address register at offset `0x40`.
3. Maps `480 * 360 * 2` bytes at that address and writes them, unchanged, to
   a new file it creates exclusively with mode `0600`.

The host reads the raw file back, converts each little-endian RGB565 pixel to
8-bit RGB and writes `build/toolbox/device/screenshots/NAME.png`. `NAME` must
be a filename, not a path; the default is timestamped. The temporary files are
removed from the device afterwards even when a step fails. The helper needs
`CONFIG_DEVMEM` without `CONFIG_STRICT_DEVMEM`, which the product
[kernel configuration](kernel.md) provides.

## System information

```sh
toolbox dev device collect-sysinfo
```

`collectSysinfo` creates `/tmp/tempo-sysinfo-<stamp>` on the device, runs each
entry of `diagnosticCommands` as root through `sh -c`, and downloads the output
to `build/toolbox/device/sysinfo-<stamp>/`. Every command's stderr is captured
too and kept as `<name>.err` when it is not empty, so an absent debugfs file
or unmounted filesystem is recorded rather than hidden. The remote directory is
removed afterwards. If the device could not produce `device-tree.dts`, the host
decompiles the downloaded `device-tree.dtb` with its own `dtc` or the
container's. The run ends by writing `SHA256SUMS` over every capture and fails
if `uname.txt` is missing.

The captures, by area:

| Area | Files |
| --- | --- |
| Kernel identity | `uname.txt`, `version.txt`, `cmdline.txt`, `config.gz.note.txt` from `/proc/config.gz`, `modules.txt` |
| Device tree | `device-tree.dtb`, `device-tree.dts`, `device-tree.compatible` |
| Log and memory map | `dmesg.txt`, `journal.txt`, `iomem.txt`, `interrupts.txt`, `meminfo.txt` |
| CPUs | `cpuinfo.txt`, `cpus.txt` with online state and cpufreq if any, `uptime.txt` |
| Storage | `partitions.txt`, `blocks.txt` with per-partition sector starts, `mounts.txt` |
| debugfs | `debugfs.txt`, `gpio.txt`, `pinctrl.txt`, `clk_summary.txt`, `clk_orphans.txt`, `regulator_summary.txt`, `pm_genpd.txt`, `devices_deferred.txt` |
| Buses and devices | `i2c_devices.txt`, `platform_devices.txt` with the bound driver per device, `sys_class.txt`, `dev.txt`, `input_devices.txt`, `usb_gadget.txt` |
| Peripherals | `asound.txt`, `power_supply.txt`, `backlight.txt`, `thermal.txt`, `rtc.txt`, `drm.txt`, `graphics.txt`, `tty.txt` |
| Userland | `systemctl_failed.txt`, `services.txt`, `units_tempo.txt` for the `tempo*`, `tempod*` and `plymouth*` units, `ps.txt`, `ip.txt` |

The debugfs entries do not mount debugfs themselves; they report that it is
absent instead. `platform_devices.txt` and `devices_deferred.txt` together are
the first place to look when a driver from the fork has not probed.

## Audio capture and analysis

These run on the Linux host, not on the device, and need no checkout: the
`diagnostics` area is dispatched before the repository is located.

```sh
toolbox dev diagnostics capture-a2dp [BLUETOOTH_ADDRESS] [OUTPUT_DIRECTORY]
toolbox dev diagnostics analyze-tone capture.wav --minimum-gap-ms 5
```

`capture-a2dp` records a Y2 that is already connected to the host as an A2DP
source. The default peer address is `00:00:46:65:82:01` and the default output
is `build/btdiag`. The host needs `pactl` and `pw-record`. `A2dpCapture` reuses
or creates a silent `bt_diag` sink, routes only that peer's streams to it and
records the sink monitor as 48 kHz stereo signed 16-bit WAV, with a `.meta`
file beside it recording timestamps, peer, sink index and PCM format. Ctrl-C
finalises the WAV and cleans up; the sink stays for the next run.

`analyze-tone` measures continuity in a captured steady test tone. Leading and
trailing silence are excluded. `--silence-db` sets the silence threshold and
defaults to -45; `--minimum-gap-ms` sets the smallest reported gap and
defaults to 5. The exit code is the result: 0 for a continuous tone, 1 for no
active tone, 2 for dropouts, 64 for invalid input. Music or speech is not a
valid input.

## Splash harvest and install

`device_diagnostics.dart` also holds two device operations the splash build
uses. `toolbox dev os splash harvest` finds Plymouth's script plugin on the
device, follows `ldd` for the daemon, client and renderer, adds the theme and
`/etc/plymouth`, downloads all of it into `build/os/rootfs/plymouth-payload`
and writes a `plymouthd.conf` selecting the `tempo` theme. That payload is what
the initramfs packs. `toolbox dev os splash install` pushes the theme from
`platform/splash/plymouth/tempo` onto a running device and selects it. Both
are described from the splash side in [Boot splash](splash.md).
