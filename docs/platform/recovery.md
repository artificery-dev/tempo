# Tempo Recovery

Tempo Recovery is a small Linux environment that runs entirely from RAM and
exposes the Y2's eMMC to a host over USB. Toolbox boots it through the
MediaTek download agent on a powered-off player, then backs up, restores and
flashes through a bulk transfer service instead of the vendor agent. Booting
recovery writes nothing and mounts nothing; every storage operation is an
explicit, acknowledged host request. The same kernel and initramfs are also
packaged as an LK-format image and shipped as the `RECOVERY` partition.

## Components

| Where | What |
| --- | --- |
| `platform/recovery/build.sh` | The toolchain-container build: kernel, display modules, service, UI, entry stub. |
| `platform/recovery/init` | The initramfs `/init`: no root search, no mounts, storage set read-only. |
| `platform/recovery/start-usb` | Configures the USB gadget and starts the transfer service. |
| `platform/recovery/start-display` | Loads the display modules, routes the panel reset and starts the UI. |
| `platform/recovery/transfer.c` | The FunctionFS bulk service and its protocol. |
| `platform/recovery/ui.c` | The DRM status screen and the `status` writer. |
| `platform/recovery/entry.S`, `entry.ld` | The RAM entry stub the download agent jumps into. |
| `platform/recovery/pack.py` | Builds the RAM payload and the wrapped agent, `ramboot-DA.bin`. |
| `platform/kernel/linux/drivers/power/supply/mt6323-charge-policy.h` | The recovery charging policy, host-testable. |
| `packages/tempo_build/lib/src/recovery.dart` | `recoveryImage`, the build cache and `toolbox dev os recovery build`. |
| `packages/tempo_build/lib/src/distribution.dart` | Puts `recovery.img` into bundles and the SP Flash Tool folder. |
| `packages/tempo_usb/rust/src/recovery.rs` | The host client for the bulk protocol. |
| `packages/tempo_usb/rust/src/recovery_workflows.rs`, `da.rs` | Backup, restore and flash over recovery, and the agent session that RAM-boots it. |
| `packages/toolbox_core/lib/toolbox_core.dart` | Chooses recovery or the Legacy Download Agent for each Toolbox operation. |
| `toolbox/linux/70-tempo-recovery.rules` | The udev rule that grants the desktop session access on Linux. |
| `platform/firmware/DA.img`, `stock/rockbox-MTK_AllInOne_DA.bin` | The legacy agent, and the base of the RAM-boot wrapper. |

## Build

`toolbox dev os recovery build` runs `platform/recovery/build.sh` inside the
toolchain container and then packages `recovery.img`. Native Toolbox builds
and distribution packaging call `ensureRecovery`, which hashes every input,
records them with the kernel commit in `build/recovery/build-state.json`, and
rebuilds only when an input or an output has changed. The kernel checkout must
have no uncommitted changes.

The build generates a fresh kernel configuration from `multi_v7_defconfig`
plus `platform/kernel/config/y2.config`, then forces the recovery command line
and disables sound, WLAN, Bluetooth, CONSYS and the framebuffer console:

```
console=ttyS0,921600n8 earlycon=uart8250,mmio32,0x11002000 loglevel=8
ignore_loglevel clk_ignore_unused maxcpus=1 rdinit=/init panic=0
mt6323_charger.recovery_1a=1
```

The initramfs is built into the kernel from a `gen_init_cpio` manifest: the
shared `platform/rootfs/initramfs/busybox/busybox-armv7l`, `/init`,
`recovery-ui`, `recovery-transfer`, `start-usb` and `start-display`. The
display stack loads from the initramfs. The script checks `DRM_KMS_HELPER`,
`DRM_DISPLAY_HELPER`, `MTK_SMI`, `DRM_PANEL_GC9503V` and `DRM_MEDIATEK` in the
resolved configuration, fails if any is disabled, and embeds under `/modules`
exactly those left as modules, in load order. The service is compiled static
with `-D_FILE_OFFSET_BITS=64`; the UI is static against `libdrm`. The build
then assembles the entry stub, the zImage and the Y2 device tree.

## Image packaging

`payload.bin` and `ramboot-DA.bin` are the RAM-boot pair. `pack.py` lays the
payload out for the address the agent's second stage normally loads at:

```
0x80000000  entry.bin      at most 0x1000 bytes
0x80001000  the DTB        at most 0x7000 bytes
0x80008000  zImage
            256 zero bytes the vendor stage 1 counts as the hash trailer
```

It then takes `stock/rockbox-MTK_AllInOne_DA.bin`, whose SHA-256 is pinned,
finds the single MT6582 entry in the agent's table, confirms its first stage
loads at `0x200000` and its second at `0x80000000` with a 256-byte signature,
and replaces the second stage's SHA-1 inside the first stage with the hash of
the new payload, so the first stage accepts the payload as its second stage.
`manifest.json` records the addresses and hashes. The vendor preloader is
copied beside them as `preloader.bin` because the agent needs its EMI settings
to configure DRAM; it is never flashed by this path.

`recovery.img` is the LK-format storage image. `recoveryImage` checks the
zImage magic and the DTB magic, wraps kernel plus appended DTB in a 512-byte
MTK header named `KERNEL`, wraps a placeholder ramdisk of nine 2048-byte pages
in one named `RECOVERY`, and emits an Android boot image with 2048-byte pages
and the same load addresses as `boot.img`. The normal automatic-install
initramfs is never attached; the recovery kernel carries its own. The image
must fit the 16 MiB partition or the build fails.

Distribution packaging copies `recovery.img` into `build/dist/images/` and
the SP Flash Tool folder, lists it in `SHA256SUMS`, checks it against the
scatter's `RECOVERY` span, and the Tempo layout places it at `0x3900000` with
the same 16 MiB capacity as boot. Toolbox bundles carry `ramboot-DA.bin`,
`payload.bin` and `preloader.bin` under `recovery/` beside the executable.
See [Boot and flashing](boot-and-flashing.md) for the layout and
[Firmware inputs](firmware-inputs.md) for the stock files.

## Entering recovery

Toolbox's Backup & Restore uses Tempo Recovery by default; the Advanced options
expose the Legacy Download Agent, which runs the same operations through
`DA.img` and the vendor agent's eMMC commands. `toolbox_core` passes
`recovery` before `backup`, `restore` and `flash` unless that override is
set, and backup resume always uses the legacy agent.

`connect` in `recovery_workflows.rs` waits up to five minutes for either a
running recovery or a powered-off Y2. When it finds a MediaTek boot device,
vendor `0x0e8d` with product `0x2000`, `0x2001` or `0x0003`, and no recovery,
it opens the port, probes the chip, parses `ramboot-DA.bin`, and calls
`boot_ram_with_progress` with the payload as the second stage. The agent
session is the vendor one: security query, first-stage upload with checksum,
jump, then the second stage at `0x80000000` with a zero signature length. No
eMMC write, erase or reboot command is issued.

`entry.S` runs in ARM state at `0x80000000`. It refuses to continue if the MMU
or data cache is on, stops the boot watchdog, invalidates the instruction
cache and branch predictor, prints a marker on UART0, and calls the agent's
initialised USB transport to send `TRDY` to the host, or `TCAC` on a bad
state. It then jumps to the zImage with `r2` pointing at the DTB. The host
fails the operation on anything but `TRDY`, then polls for the recovery USB
device.

The `RECOVERY` partition holds the same environment in the container LK reads
for `BOOTIMG`; only the DA path sends the payload through RAM.

## The environment

`/init` installs busybox, mounts `proc`, `sysfs`, `devtmpfs` and a `tmpfs` on
`/run`, waits up to ten seconds for `/dev/mmcblk0boot1`, and marks every
`mmcblk*` block device read-only with `blockdev --setro`. There is no root
search, automount, installer or `switch_root`. A shell is offered on the
gadget console `/dev/ttyGS0`; `start-display` and `start-usb` run in the
background with logs under `/run`.

`start-usb` builds a configfs gadget with vendor `0x0525`, product `0xa4aa`,
manufacturer `Tempo`, product `Recovery` and serial `tempo-recovery`, with an
ACM console and a FunctionFS instance for the transfer service. It starts
`recovery-transfer --allow-boot-writes`, waits for `/run/transfer-ready`, and
binds the UDC. The service publishes a vendor interface, class `ff`, subclass
`54`, protocol `01`, with one bulk IN and one bulk OUT endpoint. On Linux
`toolbox/linux/70-tempo-recovery.rules` tags that device for the active
session and tells ModemManager to ignore it.

`start-display` loads the modules, passing `bringup_phy=1` and the DSI rate to
`mediatek-drm`, routes GPIO112 to the LCM reset that LK normally sets up,
pulses the panel reset, and runs `recovery-ui`.

## The bulk protocol

Every frame is a 48-byte little-endian header, optionally followed by a
payload of at most 1 MiB. Both ends give a stalled transfer thirty seconds.

```
0x00  char[8]  "TEMPREC1"
0x08  u32      op            responses set bit 31
0x0c  u32      status        0 ok; non-zero with an error message as payload
0x10  u64      offset        request: chunk offset; response: bytes completed
0x18  u64      length        request: range or chunk length; response: total
0x20  u32      size          payload bytes
0x24  u32      crc           CRC-32 of the payload
0x28  u32      region        0 user, 1 boot0, 2 boot1
0x2c  u32      flags         bit 0 boot writes authorised, bit 1 verify
```

| Op | Command | Effect |
| --- | --- | --- |
| 1 | `INFO` | JSON: protocol version, supported extensions, `max_chunk`, the three region sizes and whether boot writes are permitted. |
| 2 | `BEGIN_READ` | Open a range for reading. |
| 3 | `BEGIN_WRITE` | Open a range for writing. |
| 4 | `READ` | Return the next chunk; the host must `ACK` before the next one. |
| 5 | `WRITE` | Write the next chunk, sync, optionally read it back and compare. |
| 6 | `ACK` | Acknowledge the last chunk; the service advances its completed count. |
| 7 | `FINISH` | Sync and close; only valid when every byte is done. |
| 8 | `CANCEL` | Sync and close an open transfer; a no-op when nothing is open. |
| 9 | `CONTEXT` | Set the title and detail the screen shows for the next transfer. |
| 10 | `FILL` | Write a chunk that repeats a four-byte pattern, sent as four bytes. |
| 11 | `REBOOT` | Sync and restart the player; refused during a transfer. |
| 12 | `SETUP` | Write the payload to `/first-run-config.json` in the Tempo root filesystem; refused during a transfer. |
| 13 | `TIME` | Set the system and hardware clocks to the UTC seconds in `offset`; refused during a transfer. |

A `BEGIN` requires no open transfer, a region of 0 to 2, a non-zero length,
512-byte alignment of offset and length, a range inside the device's reported
capacity, and no `/dev/mmcblk` device in `/proc/mounts`. Offsets and lengths
are 64-bit throughout and the service uses 64-bit file offsets, so ranges
above 4 GiB on the 7.3 GiB user area work like any other. A write to region
1, the boot partition holding the preloader, additionally needs the service's
`--allow-boot-writes` and flag bit 0. For a write the service clears
`force_ro` on the boot partition and the block device's read-only flag,
reopens it read-write, and restores both when the transfer closes.

Chunks must arrive in order: each `READ`, `WRITE` or `FILL` offset must equal
the range base plus the completed count, and each `ACK` must name the offset
just past the outstanding chunk. Every response carries the completed count,
which the host checks against its own after each chunk. Every write chunk is
followed by `fdatasync`, and with the verify flag the service reads it back
and compares before acknowledging.

CRC-32 covers every payload in both directions. Whole-image integrity lives
in the host workflow: packages and backups are checked against their manifest
SHA-256 before USB is opened, and `flash --resume` reads each partition back
and skips those already matching.

`SETUP` is the one request that mounts storage. The host names the offset
and length of the `rootfs` mapping it flashed; the service re-reads the
partition table, requires the first partition to start at that offset and be
at least that long, clears the read-only flags, mounts it as ext4 for this
request alone, writes the payload (at most 64 KiB, no NUL bytes) as a file
only root can read, unmounts, syncs and sets the flags again. A foreign
image, whose first partition is elsewhere or missing, is left untouched.
`TIME` takes seconds between 2020 and 2100, calls `settimeofday` and sets
`/dev/rtc0`. `INFO` advertises both as `setup` and `time`.

Any failure reply syncs an open write, closes the disk, publishes an error to
the screen and returns status 1 with the message as payload. A malformed
frame, a timeout or a lost host ends the session; the service syncs, closes,
re-enumerates USB by unbinding and rebinding the UDC so the host can
reconnect, and shows Recovery Ready again. Interrupted writes are not replayed.

The host client mirrors these rules. `UsbBulk::open` requires exactly one
matching device, and `Client` checks each response header and CRC. Transfers
use `FILL` for uniform chunks when the service advertises it, sample
throughput every 200 ms, and send `CANCEL` on any error or when the
cancellation flag is raised. `geometry` rejects a device whose regions are
not the Y2's.

## Workflows

A backup writes one continuous gzip stream in the legacy layout: boot0, boot1,
a zeroed RPMB gap, then the user area. Restore and flash prepare the package
first, build the write plan, and order the preloader write last; that write
needs `--allow-preloader`, exactly one mapping and a valid preloader header.
Each partition is written under a screen context such as `Flashing boot` with
`Partition 2/5 - write + readback verification`. A flash given `--setup FILE`
reads first-run choices from that file before USB is opened, checks them the
way the player will (`platform/rootfs/tool/first_run.dart`), replaces the
password with its sha512-crypt hash, and after the last partition sends them
as `SETUP` for the package's `rootfs` mapping; a package without one refuses
the flag. Every flash and restore then sends `TIME` with the host's clock, so
the player boots knowing the time; a recovery too old to offer it is left
alone. When the work is done the host sends `REBOOT` unless `--no-reboot`
was given.

## The display and charging

`recovery-ui` waits up to thirty seconds for `/dev/dri/card0`, takes DRM
master, picks the connected connector and draws a 480x360 frame with the
Tempo icon and wordmark. The top right shows battery percentage, voltage and,
while a charger is online, the current limit, read from sysfs once a second.

The status comes from `/run/tempo-recovery-state`, which the service and the
`recovery-ui status` command replace atomically by rename. The record is mode,
percentage, title, detail, then completed bytes, total bytes, monotonic sample
time and bytes per second; a detail containing ` - ` splits into a third
line. Transfer modes with a known total show a bar with percentage, MiB counts
and speed, zeroed when the sample is older than two seconds. Unknown totals
and the preparing and stopping phases show a spinner. Idle shows Recovery
Ready.

Charging is handled by the kernel driver with `recovery_1a=1`. The policy in
`mt6323-charge-policy.h` starts at 450 mA and promotes to 1 A only after three
consecutive healthy samples: the required charger status bits set, the fault
bit clear, and battery voltage known and below 4.15 V. Any failed sample
resets the count and drops back to 450 mA. A cable replug re-runs the hardware
initialisation, and a latched-off charge path is re-enabled below 4.15 V.

## Leaving recovery

Nothing in recovery persists. A RAM boot leaves the eMMC exactly as it was
except for the ranges the host explicitly wrote, so any restart returns to the
normal boot chain: the `REBOOT` command syncs and calls `reboot`, and a power
cycle does the same. Nothing is ever mounted, so there is nothing to unmount.
