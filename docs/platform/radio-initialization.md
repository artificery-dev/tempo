# Radio initialization

The MT6582's Bluetooth and WiFi share hardware with the cellular modem, and
on the Y2 the modem is what brings that hardware up. Tempo therefore runs the
stock modem firmware once at boot, lets it initialise, and powers it off again
before `bluetoothd` and the WiFi driver start. Nothing about this provides
cellular service.

The helper lives in `platform/bluetooth/` and runs as
`tempo-modem-bootstrap.service`.

## Components

| Where | What |
| --- | --- |
| `platform/firmware/stock/modem_1_2g_n.img` | The vendor modem firmware, carried in Git LFS. |
| `platform/bluetooth/mmio.c` | Native helpers: `/dev/mem` mapping, ordered 32-bit MMIO, the modem lock. |
| `platform/bluetooth/tool/bootstrap.dart` | The entry point compiled to the `bootstrap` executable. |
| `platform/bluetooth/tool/modem_hardware.dart` | `ModemHardware`: power sequencing, memory setup and the CCIF message loop. |
| `platform/bluetooth/tool/modem_runtime.dart` | Generates the CCCI shared-memory layout the firmware expects. |
| `platform/bluetooth/tool/modem_filesystem.dart` | `ModemFileSystem`: the in-memory filesystem the firmware reads and writes during boot. |
| `packages/tempo_build/lib/src/modem_protocol.dart` | Memory addresses, sizes, the firmware hash and the filesystem request parser, shared by the helper and its tests. |
| `packages/tempo_build/lib/src/bluetooth.dart` | `toolbox dev os bluetooth build`. |
| `packages/tempo_build/lib/src/radio_distribution.dart` | Packaging checks that keep player captures out of releases. |
| `platform/bluetooth/tempo-modem-bootstrap.service` | The systemd unit. |

## Firmware

The release input is `modem_1_2g_n.img`, taken from
`/system/etc/firmware/modem_1_2g_n.img` in the stock ROM. Its SHA-256 is pinned
as `modemFirmwareHash`:

```
5059775975cbf6ab74c43978ca8f65d9a274b83585f456134e39b09f6dc7a4f1
```

Both the build and the helper refuse a file with any other hash, or one larger
than the modem ROM region.

## Build

`toolbox dev os bluetooth build` produces `build/os/bluetooth/`:

- `mmio.so`, cross-compiled from `mmio.c` in the toolchain container
- `bootstrap`, an ARM executable from `dart compile exe`
- `tempo-modem-bootstrap.service` and `modem_1_2g_n.img`, copied in
- `build-manifest.json`, SHA-256 of every file above

Rootfs staging verifies the manifest, installs the files under
`/opt/tempo-modem-diag/`, removes any `fixture` directory left from earlier
images, and enables the unit. Distribution packaging additionally checks the
rootfs image for `/opt/tempo-modem-diag/fixture` and
`/var/log/tempo-modem-bootstrap` and refuses to package an image that contains
either, so a cached image cannot ship player-specific data.

## Boot ordering

The unit is a oneshot with `RemainAfterExit`, ordered after `local-fs.target`
and before `bluetooth.service`, both `tempod` units, `mt6582-wifi-power` and
`wpa_supplicant`. Drop-ins under `platform/rootfs/overlay` make
`bluetooth.service` and `mt6582-wifi-power.service` `Requires=` it, so neither
starts if initialisation fails. Start is limited to forty seconds. `ExecStopPost`
runs the helper again with `--cleanup`, which powers the modem off if a previous
run left it owned.

## What the helper does

`bootstrap FIRMWARE` runs as root and takes these steps in order.

1. **Validate the firmware** against the pinned hash. With `--validate-only` it
   stops here.
2. **Check the board.** The device tree must be `innioasis,y2` on
   `mediatek,mt6582`; `/sys/kernel/ccci` must not exist, so it never competes
   with a stock CCCI driver; `/proc/iomem` must be readable and the modem ROM
   and shared-memory regions must not overlap Linux System RAM.
3. **Take the modem lock**, an exclusive `flock` on
   `/run/tempo-modem-bootstrap.lock`. A second instance fails.
4. **Refuse a configured modem.** If MD1 already reports powered on and any of
   its configuration registers are non-zero, something else owns it. A modem
   LK left powered but unconfigured is normalised to off first.
5. **Record ownership** in `/run/tempo-modem-bootstrap.owned` with the current
   boot ID, so `--cleanup` knows whether there is anything to undo.
6. **Load memory.** The ROM region at `0xbe000000` is zeroed and the firmware
   copied in. The shared-memory region at `0xbf600000` receives the layout from
   `modemSharedMemory()`: the CCCI runtime table of UART, control and filesystem
   buffer addresses, and the `misc_info` block. It starts from zeroed memory and
   fixed constants, not from a snapshot of any player.
7. **Power on** MD1 through the SPM and bus-protection registers, program the
   modem's address remapping so it sees the ROM at its expected offset, and
   reset the CCIF mailbox.
8. **Serve the boot.** The message loop polls CCIF for up to thirty seconds.
   It answers the firmware's initial handshake with the shared-memory tag,
   records `NORMAL_BOOT_ID` as boot-ready, consumes the unused cellular TX
   credits, PCM and tty notifications, and answers filesystem requests on
   channel 14. Any other channel is a failure; its buffer is dumped to the log
   directory for analysis. The run completes once the modem has been ready for
   five seconds with no filesystem request in the last five seconds.
9. **Power off** MD1, always, whether the run succeeded, failed or was
   cancelled by SIGTERM. The ownership file is removed and the lock released.

Logs go to `/var/log/tempo-modem-bootstrap/`, or `--output DIR`. The unit runs
with `UMask=0077` so that directory is root-only.

## The RAM filesystem

The modem firmware expects a filesystem service on the application processor.
`ModemFileSystem` implements the request set it uses at startup (open in both
forms, read, write, seek, close, file size, delete, create directory, get
attributes, disk info, a find-first that always reports no files, and commit)
over an in-memory tree that starts empty each run. It caps the tree at 128
directories, 256 files, 128 open handles and bounded per-file and total sizes. The modem creates its own calibration and
identity records during boot. Paths must use the `X:`, `Y:` or `Z:` drive names
with plain ASCII components and no traversal.

Nothing is read from eMMC, from NVRAM partitions, or from a recording of
another player, and nothing is written outside RAM, including writes the
firmware directs at its persistent drives. Requests outside the supported set,
oversized packets, mismatched buffer indices and exhausted resource limits all
fail closed and lead to the same power-off path. This is a startup helper for
this one firmware, not a general modem filesystem.

## Distribution boundary

Player captures, NVRAM contents, identity records and RAM snapshots are not
release assets and are not needed by this design. The build rejects a
`fixture/` directory containing `fs.bin` or `smem.bin`, staging deletes it from
the image, and packaging refuses an image that still has it. Historical captures
kept locally for analysis stay outside the repository.
