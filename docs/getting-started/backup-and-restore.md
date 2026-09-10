# Backups and going back to stock

Tempo leaves the MediaTek boot chain alone, so a Y2 running Tempo can always
be reached over USB and always be put back. The way back is a full backup of
the chip made before you installed, restored through the same Toolbox
workflow; failing that, a stock ROM in SP Flash Tool scatter form can be
imported directly. This page describes what a backup holds, how to make and
restore one, how a legacy ROM goes on, and what Tempo Recovery is doing on the
player's screen while any of that happens. The workflow steps themselves are
described in [Installing Tempo](installing.md#the-workflow).

## What a full backup contains

A Toolbox backup is one gzip-compressed image of the whole eMMC, saved as a
`.img.gz` file. It is read from the chip in a fixed order and nothing on the
player is changed while it is made.

| Section | Size | Content |
| --- | ---: | --- |
| BOOT1 | 4 MiB | The vendor preloader. |
| BOOT2 | 4 MiB | The second hardware boot region. |
| RPMB gap | 512 KiB | Zeros. Tempo never reads or writes the RPMB. |
| User area | 7.28 GiB | LK, the vendor partition tables, the boot and recovery images, the logo, and every filesystem. |

The uncompressed image is 7,827,095,552 bytes, a little under 7.3 GiB. How
much smaller the `.img.gz` is depends on how much of the chip is empty. Plan
on 8 GB of free space for the file itself on the desktop, and Toolbox needs the
same 8 GB again as temporary space to decompress a backup before restoring
it. In the browser, the backup is staged in the browser's own storage and
downloaded when complete; if the browser cannot promise 8 GB of storage, Toolbox
asks for a file destination instead, and if the browser cannot offer one, the
message **Free at least 8 GB of browser storage or use the native Toolbox**
appears.

## Creating a backup

Choose **Create a backup** in **Backup & Restore**. The **Destination** step
explains that the backup includes BOOT1, BOOT2 and the full user area and that
the player is only read. **Choose backup destination** picks the file; an
existing file is never overwritten. The **Options** step offers only **Reboot
after success**; the format is fixed. **Review** lists the destination,
the format as gzip `.img.gz`, **Included BOOT1, BOOT2, full user area**, and
states **Your player's storage will not be changed.**

Press **Connect and back up** and connect the powered-off player, exactly as
for an installation. The page shows **Backup started**, a progress bar with
the rate and time remaining, and at the end **Creating the complete gzip
backup** while the file is finished. The result reads **Backup complete**
with the file name. On the player, Tempo Recovery shows the same progress
under the title **Backing up player**.

Keep the file somewhere safe and name it for the player it came from. It is
the only copy of the stock software, the vendor partition tables and this
particular unit's preloader.

## Restoring a backup

Restore is a desktop-only operation. Choose **Restore a backup**, then drop
the `.img.gz` onto **Choose a backup to restore** or browse with **Choose
backup**. The file must be a gzip file; anything else is refused with
**Choose a gzip-compressed Toolbox backup**.

Toolbox decompresses and validates the whole backup before it opens USB. It
checks the gzip trailer, confirms the image is exactly the Y2's size, and
hashes it, so a truncated or corrupt file fails here and not half way through
a write. That is what **Validation: Before USB connection** on the
**Review** step means.

A restore writes the same way an installation does, with the same options,
and Tempo Recovery shows it under the title **Restoring**.

| What | Restore behaviour |
| --- | --- |
| User area | Written in full and read back for verification by default. |
| BOOT2 | Written and verified. |
| BOOT1, the preloader | Skipped unless **Allow preloader flashing** is enabled and acknowledged for this restore. |
| RPMB | Never restored. |
| Reboot | The player restarts on success unless **Reboot after success** is off. |

Restoring the user area and BOOT2 is enough to return a Tempo player to
stock, because Tempo never changed the preloader. Enable preloader flashing
only if you know the preloader itself was damaged, and read
[the acknowledgement](installing.md#the-preloader-acknowledgement) first: an
interrupted preloader write is the one failure the boot chain cannot recover
from. When it is enabled, Toolbox checks that the backup's preloader carries
valid headers and writes it last.

**Skip matching data** under **Advanced** makes a restore compare each range
with the backup before writing it, which turns a second attempt after an
interruption into a short one.

## Legacy backups and the command line

The Toolbox command line accepts one more backup shape: a folder made by the
mtkclient-style tooling, holding `boot1.img`, `boot2.img`, a zstd-compressed
`emmc-user.img.zst` and a `backup.json` describing them. `toolbox restore`
takes either a `.img.gz` or such a folder, validates every chunk hash against
the description, and applies the same BOOT1 and RPMB rules as the desktop
app. `toolbox backup --resume` can finish an interrupted backup from such a
folder, reusing its verified chunks. Both need `--yes` to write, and preloader
writes need `--allow-preloader` on top. Backup resume always uses the legacy
download agent.

```sh
toolbox backup y2-stock.img.gz
toolbox restore y2-stock.img.gz --yes
```

## Restoring a legacy scatter ROM

If you have no backup, Toolbox can install a stock ROM published for SP Flash
Tool. Choose **Flash a firmware** on the desktop and give it either the ROM's
ZIP file or its scatter text file sitting next to the image files. The ROM
must be an Innioasis Y2 MT6582 scatter ROM with exactly one scatter file; no
SP Flash Tool installation is involved.

Toolbox reads the scatter's user-area partitions only, converts the
scatter's addresses to the chip's, unpacks Android sparse images, and checks
that each image fits its partition. The card shows **Legacy SPFT ROM · Preloader excluded**:
the ROM's preloader row is dropped, so a stock ROM install can never brick the
player. From there the options, review and connection are the same as for a
Tempo package, and readback verification applies to every written range.

## Tempo Recovery

Tempo Recovery is a small Linux system that runs entirely from the player's
RAM. It is the default transfer method on the desktop for backup, restore and
flash. When you connect a powered-off Y2, Toolbox sends the recovery
environment through the MediaTek download agent, the player's screen lights
up with the Tempo icon and **Recovery Ready**, and from then on Toolbox talks
to a fast bulk transfer service instead of the vendor agent.

| On screen | Meaning |
| --- | --- |
| Recovery Ready | Idle, waiting for Toolbox. |
| Battery percentage, voltage and current limit | Read from the PMIC once a second; the current limit appears while a charger is connected. |
| A title and a partition line with a bar | A transfer in progress, with percentage, MiB counts and speed. |
| A spinner | A phase with no known total, such as preparing or stopping. |

Booting recovery writes nothing and mounts nothing. Every storage device is
marked read-only when it starts, and only an explicit request from Toolbox
lifts that for the range being written. The preloader region additionally
needs the acknowledgement described above. If the cable is pulled or Toolbox
stops, the service closes what it was doing, reconnects its USB device and
shows **Recovery Ready** again. A restart or a power cycle returns the player
to its normal boot chain with the chip exactly as Toolbox left it. The same
environment is also written to the player's recovery slot during a Tempo
installation.

Tempo Recovery charges the battery while it runs, at 450 mA to begin with and
1 A after three consecutive healthy readings of the charger and battery.

The Linux desktop build carries a udev rule file, `70-tempo-recovery.rules`,
beside its executable. It lets your desktop session open the recovery USB
device. If Toolbox reports that it cannot open Tempo Recovery on a player
whose screen already says **Recovery Ready**, its message asks you to install
that file into `/etc/udev/rules.d`, reload the udev rules and reconnect the
player.

## The Legacy Download Agent

The **Advanced** section of the **Options** step has a **Legacy Download
Agent** switch. With it on, Toolbox runs the same backup, restore or flash
through the vendor download agent alone, without starting Tempo Recovery.
It is slower and shows nothing on the player's screen, but it needs nothing
but a powered-off Y2 in boot mode. The browser app can only use this method,
and backup resume always does. The rules are unchanged: the preloader is
skipped unless acknowledged, RPMB is never touched, readback verification is
on by default, and the player restarts on success.

## Getting back to stock

| You have | Do this |
| --- | --- |
| A Toolbox `.img.gz` backup | **Restore a backup** on the desktop. The preloader stays protected; that is fine. |
| A legacy mtkclient-style folder | `toolbox restore FOLDER --yes` on the desktop. |
| A stock SPFT ROM | **Flash a firmware** with the ZIP or scatter file. Preloader excluded. |
| Nothing | The player still answers over USB as a MediaTek boot device. Obtain a stock ROM for the Y2 and use the row above. |

For how these operations are put together, see
[Device operations](../toolbox/device-operations.md),
[Tempo Recovery](../platform/recovery.md) and
[Boot and flashing](../platform/boot-and-flashing.md).
