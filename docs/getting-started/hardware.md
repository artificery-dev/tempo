# The hardware

The Innioasis Y2 is a small click-wheel music player built around a MediaTek
MT6582, a phone chip from 2014. Stock, it ships with an old Android build
underneath a player skin, and a community Rockbox port also exists for it.
Tempo replaces that software with mainline Linux, a Debian userland and a
Flutter interface, and it does so without opening the case: everything goes in
over the USB cable, and the parts of the chip that make the player reachable
over USB are left exactly as the vendor shipped them. This page describes what
is inside the Y2, what Tempo drives, and what it deliberately never touches.

## What is inside

| Part | What it is |
| --- | --- |
| Processor | MediaTek MT6582, four Cortex-A7 cores. |
| Memory | 992 MB of RAM available to Linux; the bootloader keeps its logo buffer just above that. |
| Storage | A soldered eMMC with two 4 MiB hardware boot regions, a 512 KiB RPMB region and a 7.3 GiB user area. |
| Card slot | A microSD slot, used for the media library. |
| Screen | A 480 by 360 GalaxyCore GC9503V panel on a two-lane MIPI DSI link. |
| Graphics | A Mali-400 MP2 GPU. |
| Audio | A Cirrus CS43131 headphone DAC and an Awinic AW87559 amplifier for the speaker. |
| Radios | WiFi, Bluetooth and an MT6627-class FM tuner, all inside the chip's connectivity subsystem. |
| Power | A MediaTek MT6323 PMIC that owns the charger, the battery reading, the backlight and the power key. |
| Controls | A capacitive click wheel with a centre button and four ring buttons, two volume keys and a power key. |

The FM tuner uses the headphone cable as its antenna, so FM needs headphones
plugged in.

## What Tempo uses

Tempo drives every one of those parts. The interface is a Flutter app rendered
on the Mali GPU and drawn straight to the panel, and it is steered entirely
from the wheel: jog to move, press to select, hold buttons for chords. Audio
plays through the DAC and speaker over PipeWire, and can be routed to a
Bluetooth headset. The FM tuner has its own screen. WiFi lets the player join
a network, and the USB cable doubles as a network link and a serial console
for anyone who wants to log in.

The microSD card holds music. Tempo mounts it automatically, reads cards
formatted as FAT or exFAT the way a computer leaves them, and can format a card
itself. The internal storage can hold music too; the
[Settings](settings.md) page covers choosing between them.

The battery, the charger and the power key are handled by the PMIC driver, so
the gauge on screen is the real battery voltage and charging behaves the same
way whether the player is running Tempo or sitting in Tempo Recovery.

## How the chip boots

The MediaTek boot chain runs in stages. The boot ROM in silicon loads the
preloader from the first hardware boot region of the eMMC. The preloader loads
LK, the vendor bootloader, from the user area. LK then loads a boot image and
hands over to it.

| Stage | Where it lives | Under Tempo |
| --- | --- | --- |
| Boot ROM | In the chip | Unchanged, cannot be changed. |
| Preloader | eMMC boot region 1 | Vendor binary, left alone. |
| LK | Start of the user area | Vendor binary, left alone. |
| Boot image | The vendor `BOOTIMG` slot | Tempo's Linux kernel. |
| Recovery image | The vendor `RECOVERY` slot | Tempo Recovery. |
| Logo | The vendor `LOGO` slot | Tempo's power-on picture; the charger pictures are kept. |
| Everything after | The rest of the user area | Tempo's Debian root filesystem. |

Tempo replaces the boot image and everything after it. The preloader, LK and
the vendor partition tables stay as they were, and that is the point: with the
preloader intact, a powered-off Y2 always answers over USB as a MediaTek boot
device, whatever state the rest of the chip is in. Toolbox uses that to boot
Tempo Recovery into RAM, back the chip up, and put a stock ROM back if you ever
want one. The [Backups and going back to stock](backup-and-restore.md) page
covers those operations.

## What Tempo leaves alone

| Region | Why it is left alone |
| --- | --- |
| The preloader | It is what keeps the player reachable over USB. Toolbox never writes it unless you enable preloader flashing for one installation and acknowledge the risk. |
| LK | The vendor bootloader that loads Tempo's kernel. Tempo does not build or replace it. |
| The second boot region | Read into backups, written back by a restore, never touched by an installation. |
| RPMB | Never read and never written. Backups record it as zeros. |
| The vendor partition tables | They stay at their offsets in the user area, outside the filesystem Tempo mounts. |
| The charger pictures | The logo slot holds several pictures; Tempo replaces only the power-on one. |

A Tempo installation writes five things: the boot image, the recovery image,
the power-on picture, the root filesystem, and finally a small partition table
at the start of the user area that tells Linux where that filesystem is. The
table goes last, so it is only published once the filesystem it names is on
the chip. Every write is checked against the chip's reported size first, and a
device whose eMMC is not exactly a Y2's is refused.

## Where to go next

- [Installing Tempo](installing.md) walks through Toolbox and the install.
- [Backups and going back to stock](backup-and-restore.md) covers the full
  backup and restoring stock.
- [Using the player](using-tempo.md) explains the wheel grammar.
- For the engineering behind these facts, see
  [Boot and flashing](../platform/boot-and-flashing.md) and the
  [Porting notes](../porting/display.md) on each part of the hardware.
