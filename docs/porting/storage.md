# Storage

The Y2 has two MMC controllers in use: MSDC0 drives the soldered eMMC that
holds the boot chain and the root filesystem, and MSDC1 drives the microSD
slot behind the media library. Both bind the mainline `mtk-sd` host driver
with one change, and the rest of the story is userland: a udev rule and a
oneshot unit mount the card, the `tempo-system` helper ejects and formats it,
and the daemon watches its mount ID and CID so the library knows which card
it is looking at. This page covers the hardware and the OS-level flow; the
library side is in [Cadence integration](../app/cadence-integration.md).

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts` | The `mmc0` and `mmc1` nodes and the `reg_vmmc` supply. |
| `platform/kernel/linux/drivers/mmc/host/mtk-sd.c` | Optional pinctrl and quieter command-error logging. |
| `platform/kernel/config/y2.config` | MMC, the partition scheme, ext4, vfat and exFAT, the loop device. |
| `packages/tempo_build/lib/src/tempo_layout.dart` | `TempoLayout`: the USER-area offsets and the MBR the rootfs partition comes from. |
| `config.yaml` | `device.partitions` and `rootfs`, checked against `TempoLayout`. |
| `platform/rootfs/tool/runtime.dart` | `tempo-system`: `sdmount`, `clear-reinstall-flag`, `eject-sd`, `format-sd`. |
| `platform/rootfs/tool/sd_ejector.dart`, `sd_formatter.dart` | `SdEjector` and `SdFormatter`, with the shared maintenance lock. |
| `platform/rootfs/overlay/etc/udev/rules.d/99-tempo-sd-automount.rules` | Wants `tempo-sdmount.service` on every add of `mmcblk1p1`. |
| `platform/rootfs/overlay/etc/systemd/system/tempo-sdmount.service`, `tempo-clear-reinstall-flag.service` | The mount unit and the one-shot that clears the reinstall flag. |
| `daemon/lib/src/services/device_monitor.dart` | `DeviceMonitor`: the card's path, mount ID, CID and I/O state. |
| `daemon/lib/src/services/card_host.dart` | `CardHost`: eject, resume and format behind `/api/v1/storage/card`. |
| `daemon/native/src/control.rs`, `protocol.rs` | The broker's `eject-sd` and `format-sd` ops. |
| `platform/rootfs/initramfs/init.in` | The initramfs: reinstall flag, image search and install from the card. |
| `platform/recovery/init`, `transfer.c` | Recovery's read-only view of every MMC device and its boot-region writes. |

## The eMMC

The chip has two 4 MiB hardware boot regions, a 512 KiB RPMB region and a
USER area of `0x1d2000000` bytes. Linux presents the USER area as
`/dev/mmcblk0` and the boot regions as `/dev/mmcblk0boot0` and
`/dev/mmcblk0boot1`, both read-only until `force_ro` under
`/sys/class/block/` is cleared. The vendor preloader lives in the first boot
region; nothing in Tempo reads the RPMB, and backups record it as zeros.
Every flashing tool checks the USER size before writing, so a device whose
`mmcblk0` is another size is refused as not a Y2.

The USER area carries Tempo's own MBR at sector zero. It has the disk ID
`0x54454d50`, one type `0x83` entry with LBA-only CHS sentinels, and bounds
of `rootfs_offset` and `rootfs_size` in sectors. `CONFIG_MSDOS_PARTITION` is
on and `CONFIG_CMDLINE_PARTITION` off, so that table is what makes the root
filesystem `/dev/mmcblk0p1`. The boot image, the recovery image and the
splash sit below the partition at fixed offsets and are outside any
filesystem the host can mount; the vendor MBR and EBRs stay at their own
offsets, out of the kernel's view. The layout and the two address conventions
are in [Boot and flashing](../platform/boot-and-flashing.md).

```
0x0         Tempo's MBR
0x2900000   boot image, up to 16 MiB
0x3900000   recovery image, up to 16 MiB
0x4f80000   splash
0x5180000   rootfs, mmcblk0p1, to the end of USER
```

## The host controllers

The MT6582's MSDC block matches the MT8135 generation, so both nodes bind
`mediatek,mt8135-mmc`. Their clocks are the real ones from the MT6582 clock
driver: the `MSDC30_0` and `MSDC30_1` top muxes as `source` and the pericfg
gates as `hclk`. `mtk-sd` divides the source internally and never sets its
rate. Neither node has a `vqmmc` supply or a UHS capability, so signalling
stays at 3.3 V and the card clock tops out at 50 MHz high-speed.

| | eMMC | microSD |
| --- | --- | --- |
| Node | `mmc@11230000` | `mmc@11240000` |
| Interrupt | `GIC_SPI 39`, level low | `GIC_SPI 40`, level low |
| Bus width | 8 | 4 |
| Capabilities | `cap-mmc-highspeed`, `non-removable`, `no-sd`, `no-sdio` | `cap-sd-highspeed`, `broken-cd` |
| Device | `mmcblk0` | `mmcblk1` |

`broken-cd` means the core polls for a card, because no card-detect GPIO is
described. Both hosts take `vmmc-supply = <&reg_vmmc>`, a fixed always-on
3.3 V regulator that models a PMIC output LK already enabled. Without a
supply the host's available-voltage mask is zero and card initialisation
fails with no supported voltage.

```
mmc1: mmc@11240000 {
	compatible = "mediatek,mt8135-mmc";
	reg = <0x11240000 0x1000>;
	interrupts = <GIC_SPI 40 IRQ_TYPE_LEVEL_LOW>;
	clocks = <&topckgen CLK_TOP_MSDC30_1_SEL>, <&pericfg CLK_PERI_MSDC30_1>;
	clock-names = "source", "hclk";
	bus-width = <4>;
	max-frequency = <50000000>;
	cap-sd-highspeed;
	broken-cd;
	vmmc-supply = <&reg_vmmc>;
};
```

## The mtk-sd changes

There is no MT6582 pinctrl driver, and the mainline `mtk-sd` probe refuses
to bind without a pinctrl handle and its `default` and `state_uhs` states.
The fork makes pinctrl optional: a failed `devm_pinctrl_get` is logged as
"no pinctrl; using bootloader pin config" and the handle set to null, the
state lookups run only when there is a handle, and the signal-voltage switch
skips its state selection likewise. LK muxes the eMMC pads because it boots
from them, and the microSD pads are left as LK configured them too.

The other change demotes the per-command error message in
`msdc_track_cmd_data` from a warning to debug, so command timeouts, which
polling an empty slot produces routinely, do not fill the log.

## Filesystems

`y2.config` builds in everything the device mounts; the rootfs installs no
modules tree.

| Option | Why |
| --- | --- |
| `CONFIG_EXT4_FS`, `EXT4_FS_SECURITY`, `EXT4_FS_POSIX_ACL` | The root filesystem. Security xattrs carry file capabilities; ACLs are what `systemd-tmpfiles` and logind set. |
| `CONFIG_VFAT_FS`, `CONFIG_EXFAT_FS` | Cards as they come from a host or from the Tempo formatter. |
| `CONFIG_NLS_CODEPAGE_437`, `CONFIG_NLS_ISO8859_1` | The default encodings vfat needs. |
| `CONFIG_BLK_DEV_LOOP` | Loop devices for image work. |

The root is mounted as ext4 by the initramfs with default options and handed
over with `switch_root`. `/etc/fstab` in the image lists only `proc`, so
nothing remounts it with other options. The rootfs package set includes
`exfatprogs` and `fdisk`, which the formatter uses.

The card is mounted by `tempo-system sdmount`. It creates `/mnt/sd`, reads
the partition type with `blkid`, and mounts `/dev/mmcblk1p1` with `sync` and
`noatime`; for vfat and exFAT it adds `uid` and `gid` of the device user,
`fmask=0177` and `dmask=0077`, so the unprivileged frontend owns the files
and nobody else can read them. `sync` trades throughput for a card that can
be pulled without warning.

## Automount, eject and format

`99-tempo-sd-automount.rules` adds `tempo-sdmount.service` to
`SYSTEMD_WANTS` on every add event of `mmcblk1p1`, which includes the
coldplug replay at boot, so a card present at power-on is mounted too. The
unit is a `RemainAfterExit` oneshot with `BindsTo=dev-mmcblk1p1.device`:
the device appearing starts it and the device vanishing stops it, and its
`ExecStop` is a lazy `umount -l` for exactly that surprise removal. Only the
first partition is ever automounted.

A user eject is never lazy. `CardHost` in the daemon first stops the media
side, then runs `tempo-system eject-sd <mountId>`. `SdEjector` confirms that
`/mnt/sd` still carries that mount ID in `/proc/self/mountinfo`, that the
card has no other mounts, that `/mnt/sd` holds nothing but the card, and that
`/sys/class/block/mmcblk1/device/type` reads `SD`. It runs `sync -f /mnt/sd`
so writeback errors surface first, a normal `umount`, and only then
`systemctl stop tempo-sdmount.service`. A normal unmount refuses while any
handle is open, which is the guard against ejecting under a decoder. A
repeated eject of the same card after success is a no-op.

Formatting takes the card's CID instead: `tempo-system format-sd <cardId>`.
`SdFormatter` accepts no device path, so the eMMC is never a target. It
requires the type `SD`, a matching CID and at least 32768 sectors, unmounts
`/mnt/sd`, runtime-masks and stops the mount unit, checks the CID again,
writes a DOS label with one type 7 partition from sector 2048 through
`sfdisk --wipe always`, waits for udev, checks the CID a third time, runs
`mkfs.exfat -L TEMPO` and `fsck.exfat -n`, syncs, and always unmasks and
restarts the mount unit on the way out. Eject and format share an exclusive
lock on `/run/tempo-format-sd.lock`. The native broker also exposes
`eject-sd` and `format-sd` ops that run the helper without an identity;
`format-sd` there requires `"confirm": true`.

## Card identity

`DeviceMonitor` in the Dart daemon observes the card once a second alongside
the battery and publishes the result as `/api/v1/device`.

| Field | Source |
| --- | --- |
| `cardPath` | The mount point of the first `/proc/mounts` entry whose source is `/dev/mmcblk1` or one of its partitions, with octal escapes decoded. |
| `cardMountId` | The mount ID from `/proc/self/mountinfo` for that mount point, accepted only if its source is the card. |
| `cardSourceId` | `/sys/class/block/mmcblk1/device/cid`, 32 hex digits, lowercased. |
| `cardIoBusy` | True while `/sys/class/block/mmcblk1/stat` shows requests in flight, true if the counters moved since the last observation of the same mount, otherwise null. |

The two identities do different jobs. The mount ID changes on every mount,
so eject and format carry it to be sure the card they act on is the one the
user saw. The CID is the card's own manufacturer identity, stable across
reinsertion, so Cadence can tell a reinserted card from a different one and
keep or drop its cache; a missing CID means unknown identity and a full
revalidation. A bare `/mnt/sd` directory with no mount is not treated as a
card. The frontend never reads sysfs or `/proc/mounts` itself.

## Installation

The card is also how a root filesystem reaches the eMMC. The eMMC is
writable from Linux and the card is readable, so the initramfs in the boot
image can do the install with no flashing tool involved; the details are in
[Root filesystem](../platform/rootfs.md).

1. For up to six seconds `init` tries `mmcblk1p1`, `mmcblk1p2` and the whole
   disk as vfat, exFAT, ext4 and ext2, looking for a `FORCE_REINSTALL` file.
2. Unless that flag is set, it waits up to twenty seconds for
   `/dev/mmcblk0p1`, mounts it as ext4, checks for `/etc/os-release`, and
   `switch_root`s into it.
3. Otherwise it searches the same devices for `<hostname>.ext4.gz` or
   `<hostname>.ext4`, writes the image to `mmcblk0p1` with progress on the
   splash, and boots it. A forced reinstall that finds no image still boots
   the existing root.

The initramfs never deletes the flag, so a crash during a reinstall retries
on the next boot. `tempo-clear-reinstall-flag.service`, ordered after
`tempo-sdmount.service`, runs `tempo-system clear-reinstall-flag` once per
image: it deletes the file from `/mnt/sd`, or mounts `/dev/mmcblk1p1` on a
temporary directory to do so, syncs, and touches
`/var/lib/tempo-reinstall-cleared`. A missing card is a failure, which
leaves the unit to try again on a later boot.

Recovery takes the opposite stance. Its `init` waits for `mmcblk0boot1`,
sets every MMC block device read-only with `blockdev --setro`, and mounts
nothing. Its transfer service addresses USER and the two boot regions by
device path, clears `force_ro` only for the duration of an authorised
boot-region write, and restores it afterwards; see
[Tempo Recovery](../platform/recovery.md).
