# Boot and flashing

The Y2 boots through MediaTek's chain: the boot ROM in silicon loads the
preloader from the eMMC's first hardware boot region, the preloader loads LK,
the vendor bootloader, and LK loads an Android-style boot image from the USER
area. Tempo replaces the boot image and everything after it. The preloader, LK
and the vendor partition tables stay as the vendor shipped them, which is what
keeps the player reachable over USB whatever state the kernel is in. This page
describes that chain, the two address conventions that describe the eMMC, the
layout Tempo writes, and every path that writes to the chip.

## Components

| Where | What |
| --- | --- |
| `config.yaml` `device.partitions` | The eMMC facts every flashing tool checks: USER size, the live boot image offset and size, the LOGO size and scan range, the rootfs bounds. |
| `packages/tempo_build/lib/src/tempo_layout.dart` | `TempoLayout`: the raw USER offsets, the sector-zero partition table, and the `.y2-firmware` manifest for Tempo's own layout. |
| `packages/tempo_build/lib/src/kernel.dart` | `bootImage` and `mtkHeader`: packing `boot.img`; `buildInitramfs`. |
| `packages/tempo_build/lib/src/recovery.dart` | Packing `recovery.img` and the RAM-boot pair for Tempo Recovery. |
| `packages/tempo_build/lib/src/distribution.dart` | `toolbox dev dist`: the image set, the installer package and the legacy scatter export. |
| `packages/tempo_build/lib/src/device.dart` | `toolbox dev device flash-boot`, `flash-logo` and `install-rootfs` over the USB gadget link. |
| `packages/toolbox_core/lib/live_device.dart` | `LiveDeviceOperations`: the checked, verified writes those commands perform on a running player. |
| `packages/tempo_usb/rust/src/firmware.rs` | The `.y2-firmware` manifest, the write plan and the preloader gate. |
| `packages/tempo_usb/rust/src/recovery_workflows.rs`, `da.rs`, `partitions.rs` | Toolbox's transfers through Tempo Recovery or the legacy download agent. |
| `platform/firmware/stock/MT6582_Android_scatter.txt` | The vendor scatter, the source of every partition name and size. |
| `platform/rootfs/initramfs/init.in` | The initramfs that installs the rootfs from the microSD and hands over to Debian. |

## The boot chain

```
BROM         in silicon
preloader    eMMC hardware region BOOT1
LK           USER area, the UBOOT partition
boot image   USER area, the BOOTIMG partition
initramfs    inside the boot image, then Debian on Tempo's rootfs partition
```

The preloader lives in the eMMC's first hardware boot region, wrapped in the
`EMMC_BOOT` and `BRLYT` headers with the GFH image at offset `0x800`. LK sits
in the USER area at the scatter's `UBOOT` partition. Both are vendor binaries
from `platform/firmware/stock/`, see [Firmware inputs](firmware-inputs.md),
and Tempo never builds either. What Tempo does build lands in four places:

| Image | Built by | Goes to |
| --- | --- | --- |
| `boot.img` | `toolbox dev os kernel build` | `BOOTIMG` |
| `recovery.img` | `toolbox dev os recovery build` | `RECOVERY` |
| `logo.img` | `toolbox dev os splash build` | `LOGO`, block 0 only |
| `<hostname>.ext4` | `toolbox dev os rootfs build` | Tempo's rootfs partition |

A boot image is the `ANDROID!` header with a 2048-byte page size, followed by
the zImage with its device tree appended, then the ramdisk. Each payload is
wrapped in a 512-byte MediaTek header, `KERNEL` and `ROOTFS` respectively, and
`recovery.img` labels its placeholder ramdisk `RECOVERY`. The initramfs range
is written into the device tree's `/chosen` node starting at `0x84000000`
rather than relied on from the header. An image larger than
`device.partitions.bootimg_size` is refused at build time. See
[Kernel](kernel.md) for the build and [Tempo Recovery](recovery.md) for the
recovery image.

## Two address conventions

The scatter file gives every partition two addresses. `linear_start_addr`
counts from the start of the preloader's reserved `0x1400000`, and
`physical_start_addr` counts from the vendor MBR. The two differ by exactly
`0x1400000` on every USER row, and `partitions.rs` rejects a scatter where they
do not.

Neither is a byte offset into `/dev/mmcblk0`. On the chip the vendor MBR sits
`0xb80000` into the USER area, so every raw offset the running kernel sees is
the scatter's physical address plus `0xb80000`. `generateScatter` derives that
bias from `bootimg_offset` minus the scatter's `BOOTIMG` address and refuses
any other value.

| Partition | Scatter linear | Scatter physical | Raw USER offset |
| --- | ---: | ---: | ---: |
| `MBR` | `0x1400000` | `0x0` | `0xb80000` |
| `EBR1` | `0x1480000` | `0x80000` | `0xc00000` |
| `UBOOT` | `0x3120000` | `0x1d20000` | `0x28a0000` |
| `BOOTIMG` | `0x3180000` | `0x1d80000` | `0x2900000` |
| `RECOVERY` | `0x4180000` | `0x2d80000` | `0x3900000` |
| `LOGO` | `0x5800000` | `0x4400000` | `0x4f80000` |
| `ANDROID` | `0x6580000` | `0x5180000` | `0x5d00000` |

`device.partitions.bootimg_offset` is `0x2900000` because that is where LK
actually reads the boot image; the value was found by locating the running
kernel on the chip, and `flash-boot` writes there and nowhere else. SP Flash
Tool resolves scatter addresses itself and never shows the shift. Toolbox
assumes no convention: before naming a vendor partition it reads the candidate
MBR and EBR1 sectors at three bases and requires exactly one to hold both.

## The eMMC layout

The chip has two 4 MiB hardware boot regions, a 512 KiB RPMB region and a USER
area of `0x1d2000000` bytes. Every tool checks that size before writing, and
the `.y2-firmware` manifest carries the same sizes for Toolbox to compare.

Tempo's layout in the USER area is `TempoLayout`:

```
0x0         partition table    512 bytes, Tempo's MBR
0x2900000   boot               up to 0x1000000
0x3900000   recovery           up to 0x1000000
0x4f80000   splash             up to 0x200000
0x5180000   rootfs             to the end of USER
```

The partition table is a single DOS MBR with disk ID `0x54454d50`, one type
`0x83` entry with LBA-only CHS sentinels, and the rootfs bounds in sectors.
The kernel is built with `CONFIG_MSDOS_PARTITION` and no command-line
partitions, so this table is what makes the rootfs `/dev/mmcblk0p1`. The
vendor MBR and EBRs stay where they are, out of the kernel's view, and the boot
chain data stays outside the host-mountable filesystem. `toolbox dev dist`
refuses to run if `device.partitions` and `TempoLayout` disagree.

The rootfs starts `0x200000` into the vendor `LOGO` partition and runs across
`EBR2`, `EXPDB`, `ANDROID`, `CACHE`, `USRDATA` and `FAT`. The scatter export
splits it at those boundaries into `rootfs-<name>.bin` pieces, the first
carrying the built logo, so SP Flash Tool writes it without changing the vendor
geometry; the pieces are reassembled and hashed before the scatter is written.

## The LOGO partition

`LOGO` holds a MediaTek image: the `0x58881688` header, the body size, the name
`LOGO`, then a block table and one zlib stream per block. Block 0 is the
power-on picture; the later blocks are the charger screens, for which there is
no source, so the splash build takes the stock `logo.bin` as a template and
replaces block 0 only. See [Boot splash](splash.md).

On a running device the partition is located by scanning the first
`logo_scan_size` bytes of `/dev/mmcblk0` for the header rather than by
address. The write goes ahead only when there is exactly one hit, it is page
aligned, the body fits `logo_size`, and the block count and total agree with
the header.

## Writing from the running device

`toolbox dev device` reaches the player over the USB gadget link at
`networking.usb_gadget.address` as `user.name`, overridable with
`TEMPO_DEVICE_HOST` and `TEMPO_DEVICE_USER`, using `sudo -n` when privileged.

`flash-boot [IMAGE] [--dry-run] [--force] [--no-reboot]` takes
`build/dist/images/boot.img` or `build/os/kernel/boot.img` and runs these
steps in order, stopping at the first failure:

1. The image starts with `ANDROID!` and fits `bootimg_size`.
2. The device answers and `/dev/mmcblk0` is exactly `emmc_size` bytes.
3. The eight bytes at `bootimg_offset` already read `ANDROID!`; `--force` is
   the only override.
4. The image is uploaded to `/tmp` and its SHA-256 compared with the host's.
5. `dd bs=4096 conv=fsync` at the page-aligned offset, then `sync`.
6. The range is read back and hashed again. A mismatch fails without
   rebooting, since the kernel in RAM is what can repair the write.
7. The device reboots unless `--no-reboot` is given.

`--dry-run` stops after the transfer checksum, leaving the eMMC unchanged. `flash-logo`
follows the same shape with the scan above in place of the fixed offset, saves
the current image to `build/toolbox/device/backups/logo-<stamp>.bin` first,
refuses to overwrite an existing backup, and never reboots. `--scan` only
reports the hit.

`install-rootfs [IMAGE] [--reboot]` copies `<hostname>.ext4.gz` to the card
at `/mnt/sd`, checks free space and the checksum, then touches
`FORCE_REINSTALL`; `--sd DIR` does the same to a card in a host reader. The
initramfs performs the write on the next boot.

## Distribution

`toolbox dev dist [--full]` takes `build/os/kernel/boot.img`, the built rootfs
and the stock scatter, checks the boot image header and size, runs
`e2fsck -fn` on the rootfs, refuses an image holding radio captures, builds
Recovery and the splash, and produces:

| Output | Content |
| --- | --- |
| `build/dist/images/` | `boot.img`, `recovery.img`, `logo.img`, `<hostname>.ext4.gz`, `rootfs.ext4`, `partition-table.bin`, `SHA256SUMS` |
| `build/dist/<hostname>.y2-firmware` | The installer package for Toolbox, mapped with `TempoLayout` |
| `build/dist/spft/` | The legacy scatter export: `Y2_MT6582_scatter.txt`, the rootfs pieces, `boot.img`, `recovery.img`, `DA.img`, `rootfs-pieces.json`, `build-provenance.json` |

The package writes boot, recovery, splash, the rootfs and finally the partition
table, so the table is published only after the filesystem it names is on the
chip. Every image is sector-padded and hashed, and the archive is re-read and
verified after it is written.

`--full` copies the stock preloader, `MBR`, `EBR1`, `lk.bin` and `secro.img`
into the scatter export and enables their rows, so SP Flash Tool can rebuild a
device whose boot chain is gone. The installer package never includes them; it
carries no BOOT1 mapping at all.

## What Toolbox writes

Toolbox installs a `.y2-firmware` package by its manifest, which maps image
byte ranges onto the `boot1`, `boot2` and `user` regions. Every image is
size-checked and hashed before the device is opened, ranges must be sector
aligned and non-overlapping, and the geometry must match what the chip reports.

Transfers go through Tempo Recovery by default: a powered-off player is booted
into RAM through the download agent and the recovery service writes storage
from Linux. The Advanced option selects the legacy download agent, which
writes through the DA protocol directly and is the only transport the browser
build supports. Both paths share the same plan and the same policy:

- Every `boot1` mapping is dropped from the plan unless preloader flashing was
  enabled for this installation after the acknowledgement dialog. The choice
  is never stored and resets when a task is chosen again.
- When enabled, there must be exactly one BOOT1 mapping covering the whole
  4 MiB region, its first page must carry the `EMMC_BOOT`, `BRLYT` and GFH
  headers with consistent lengths, and it is written last so a failure
  elsewhere never follows a preloader write.
- Readback verification is on by default: each written range is read back and
  compared. With resume enabled, a range is first compared and skipped when
  it already matches.
- The recovery service lifts and restores `force_ro` on a boot region only
  around an authorised write.
- The player is reset after success unless reboot-after-success is off.

Backups read BOOT1, BOOT2 and USER into one gzip image with a zeroed RPMB
gap; restore stages and re-hashes the whole file before opening USB and
follows the same BOOT1 policy.

## The initramfs and first boot

The initramfs is built into `boot.img` from `platform/rootfs/initramfs/`, with
the device's plymouth runtime packed in when `toolbox dev os splash harvest`
has provided it. Its `init` does the following:

1. Waits up to eight seconds for `/dev/dri/card0` and starts plymouth, so the
   splash takes over from LK's logo before the rootfs is mounted.
2. Mounts each microSD candidate in turn and notes a `FORCE_REINSTALL` file.
3. Without that flag, waits up to twenty seconds for `/dev/mmcblk0p1`, mounts
   it, and if `/etc/os-release` is present enables a login on `ttyGS0`, drops
   a one-shot `<hostname>-resize-rootfs.service` that grows the filesystem to
   the partition with the rootfs's own `resize2fs`, and `switch_root`s into
   Debian.
4. Otherwise looks for `<hostname>.ext4.gz` or `<hostname>.ext4` on the card,
   writes it to `/dev/mmcblk0p1` with the splash in update mode showing
   progress, and boots it.
5. A forced reinstall that finds no image boots the existing rootfs; with no
   rootfs at all it drops to a shell that reports what it found.

The flag is cleared from the card by `tempo-clear-reinstall-flag.service` in
the rootfs after a good boot, never by the initramfs, so an interrupted
reinstall retries. See [Root filesystem](rootfs.md).

## The debug build key chord

`tempo-system launch` reads whether both volume keys are held at start. When
they are, it starts the debug JIT build of the player with the Dart VM service
on `flutter.vm_service_port`, listening on every address with auth codes
disabled, which in practice means the gadget link since the firewall admits
nothing else. This is a runtime choice in the rootfs launcher, not a
bootloader mode; LK boots the same image.
