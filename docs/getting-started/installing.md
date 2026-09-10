# Installing Tempo

Tempo is installed with Toolbox, the desktop and browser application that
also hosts the player emulator. Its **Backup & Restore** section walks through
three operations in the same five steps: create a backup, restore a backup,
and flash a firmware. Installing Tempo is the third one, with a
`.y2-firmware` package as the input. This page describes what you need, what
each step shows, which options matter, and what the player does when the
transfer is done. Take a full backup first; the
[Backups and going back to stock](backup-and-restore.md) page explains why and
how.

## What you need

| Item | Notes |
| --- | --- |
| An Innioasis Y2 | Charged. Toolbox refuses any device whose storage is not exactly a Y2's. |
| A USB cable | The player's own data cable. Toolbox talks to the player over it and nothing else. |
| Toolbox | The Linux desktop app, or the browser app in a desktop Chromium browser. |
| A `.y2-firmware` package | Tempo's installer package, produced by the firmware build. |
| A full backup | Made in Toolbox before you install. Keep it. |

The desktop app is the complete installer. The browser app opens the same
workflow but with fewer transports: it needs a desktop Chromium browser with
WebUSB, it cannot boot Tempo Recovery, it cannot restore a backup, and it only
accepts `.y2-firmware` packages. When the browser cannot claim the player's
USB interface, an **Advanced** option offers **Connect via serial** through the
operating system's serial driver instead. If the browser reports that it is
unsupported, use the desktop app.

## The workflow

Open **Backup & Restore** in the sidebar. The page asks **What would you like
to do?** and offers three cards.

| Card | What it does |
| --- | --- |
| Create a backup | Save both boot areas and the complete user area as a compressed backup. |
| Restore a backup | Validate a saved Toolbox backup, then restore its mapped data to the player. |
| Flash a firmware | Install a Tempo firmware package or a legacy SPFT ROM on your player. |

Choosing a card starts a stepper with five steps: the task, **Source** or
**Destination**, **Options**, **Review**, and **Connect & transfer**, which
becomes **Result** when the operation ends. A **Back** button returns to the
previous step at any point before the transfer starts. The desktop app also
has an **Other** button below the cards that opens read-only diagnostics for
reading the partition map or exporting a single partition without writing
anything.

## Choosing the firmware

Choose **Flash a firmware**. The **Source** step shows a drop zone titled
**Choose your firmware**. Drop the package onto it or use **Choose package**
to browse. The desktop app accepts a `.y2-firmware` package, an SPFT ZIP or a
scatter file next to its ROM images; the browser accepts only `.y2-firmware`.

Toolbox validates the package before it goes any further. The manifest is
checked against the Y2's storage geometry, every image is read and its size
and SHA-256 compared with the manifest, and every write range is checked for
alignment and overlap. A progress bar labelled **Validating package** runs
while that happens. When it passes, the card shows the firmware's name,
version and icon, and the status reads **Firmware package verified and
ready**. A stock ROM chosen here instead of a Tempo package shows **Legacy
SPFT ROM · Preloader excluded**; see
[Restoring a legacy scatter ROM](backup-and-restore.md#restoring-a-legacy-scatter-rom).

## Options

The **Options** step has two switches in plain view and more under
**Advanced**.

| Option | Default | What it does |
| --- | --- | --- |
| Reboot after success | On | Restart the player when the operation finishes successfully. |
| Verify written data | On | Read written data back and compare it with the source. Adds transfer time. |
| Legacy Download Agent | Off | Use the slower legacy transfer method without starting Tempo Recovery. |
| Skip matching data | Off | Read each range first and skip it only if every byte already matches. Desktop only. |
| Allow preloader flashing | Off | Lets the package write the preloader region. Requires the acknowledgement below. |

Readback verification means that after each range is written, Toolbox reads
the same range back from the chip and compares it with the image it sent. It
roughly doubles the transfer time, and it is what turns "the transfer
finished" into "the chip holds the firmware". Input files are validated
whether or not it is on. Leave it on.

**Skip matching data** is for retrying an interrupted installation. It reads
each destination range before writing and skips it when the bytes already
match, so a second run only writes what the first one did not finish.

**Advanced** also shows the **Connection files** card on the desktop, where a
different download agent or a preloader file for memory setup can be chosen.
Both defaults are bundled; **Reset connection files** returns to them.

## The preloader acknowledgement

The preloader is the first thing the chip loads from storage and the reason a
powered-off Y2 can always be reached over USB. A Tempo package carries no
preloader, and stock ROM imports drop theirs, so ordinary installations never
write that region. Toolbox states this as **Preloader protection is on. BOOT1
package ranges are skipped.**

Switching **Allow preloader flashing** on opens a dialog titled **Allow
preloader flashing?** with this text:

```
Replacing the preloader with an invalid image, or interrupting its write, can
make the Y2 permanently irrecoverable. By selecting Enable, you acknowledge
and accept this risk.
```

**Enable** turns the switch on for this installation only. The choice is never
saved, and it resets to off whenever you pick a task again. With it on, the
package must contain exactly one preloader image covering the whole 4 MiB
region with valid headers, and that image is written last, so a failure
anywhere else never follows a preloader write. While the preloader is being
written the **Stop** button is disabled. The only reason to enable this is a
full backup restore of your own preloader; nothing in Tempo needs it.

## Review

The **Review** step lists the operation, the transfer method, which is
**Tempo Recovery** or **Legacy Download Agent**, the file, whether validation
passed, the verify and skip settings, **Preloader protection** as **Enabled**
or **Disabled**, the reboot setting, and the package's version, image count and
payload size. Below it a sentence states what is about to happen, for example
**The mapped storage ranges will be overwritten and verified by reading them
back.**

## Connecting the player

The last step shows a card with three numbered instructions and the button
**Connect and flash**. Pressing it opens one more dialog, **Flash ... ?**,
which repeats whether readback verification is on and whether the preloader
stays protected. **Flash Y2** starts the operation.

What to plug in depends on the transfer method.

| Method | What to do |
| --- | --- |
| Tempo Recovery, the default | Connect a Y2 already running Tempo Recovery, or connect the powered-off player to start recovery in RAM. |
| Legacy Download Agent | Connect the powered-off Y2, or press the reset button with a pin while the cable is connected. |

Turn the player fully off, unplug the cable, press **Connect and flash**, and
plug it back in. Toolbox waits up to five minutes for the player. A powered-off
Y2 announces itself as a MediaTek boot device for a few seconds; the desktop
app catches that automatically. On the default method Toolbox then sends Tempo
Recovery into the player's RAM through the download agent, shows **Starting
Tempo Recovery** with a progress bar, and waits for the recovery screen to
appear. Nothing on the chip is written by that boot.

In the browser, you do the catching: open the picker with the connect button
first, then connect or reset the player, and within a few seconds select the
**MT65xx Preloader** entry, or its MediaTek serial port, and click **Connect**.
A **Connecting your Y2** guide with the same steps is available from the page. If
you miss the window, open the picker again first, then reconnect or reset the
player.

## During the transfer

The page shows the current phase, a progress bar with the transfer rate and
the time remaining, and on the player's own screen Tempo Recovery shows the
same progress: a title such as **Flashing boot**, a line such as
**Partition 2/5 - write + readback verification**, the percentage, the byte
counts and the speed. The battery percentage and voltage sit in the top right,
and the player charges from the cable while it waits.

A Tempo package writes in a fixed order: the boot image, the recovery image,
the power-on picture, the root filesystem, and last the partition table that
makes the filesystem visible to Linux. The root filesystem is the large one,
and with verification on it is read back in full.

**Stop** cancels the operation. Stopping before the transfer starts leaves the
player waiting in boot mode; power-cycle it before trying again. Stopping
during a transfer discards the incomplete work and asks the player to return
to firmware. An interrupted installation is not complete; run it again, with
**Skip matching data** if you want the finished ranges left alone.

## After the transfer

On success the **Result** step reads **Installation complete** and the status
says **Firmware installed and verified. Restarting the Y2.** The player
restarts into Tempo. The first boot takes longer than later ones: the system
grows the root filesystem to fill its partition, then starts the player. The
animated splash holds until the interface draws its first frame.

If the result is **Operation failed**, the status shows the reason and
**Copy error** puts it on the clipboard. **Open Logs** shows the full history
of the session. Toolbox reads the chip's geometry and hashes before it writes,
so most failures happen before anything changes; a failed write leaves the
preloader and LK intact, and the player is still reachable for another
attempt or for a restore.

Next: [Using the player](using-tempo.md). For what Toolbox does underneath,
see [Device operations](../toolbox/device-operations.md),
[Firmware packages](../toolbox/firmware-packages.md) and
[Tempo Recovery](../platform/recovery.md).
