# Device operations

Toolbox performs five kinds of operation on a Y2's eMMC: inspection, backup,
restore, flash, and a guarded raw write of a single vendor partition. All of
them are expressed by `ToolboxOperations` in `toolbox_core` as arguments to the
`tempo-usb` helper, so the GUI, the command line and the browser build share
one policy: inputs are validated and hashed before USB is opened, the chip and
its storage geometry are verified before anything is read, every write is read
back unless the user turns that off, and the preloader region is never written
unless it was enabled for the current operation. This page describes that
policy. The transports it runs over are described in
[Tempo Recovery](../platform/recovery.md) and [USB engine](usb-engine.md), and
the addresses in [Boot and flashing](../platform/boot-and-flashing.md).

## Components

| Where | What |
| --- | --- |
| `packages/toolbox_core/lib/toolbox_core.dart` | `ToolboxOperations`: argument construction, output-file checks and the transport choice. |
| `packages/tempo_usb/rust/src/main.rs` | The helper's command line: DA-path operations, staging, events and the reset after each operation. |
| `packages/tempo_usb/rust/src/recovery_workflows.rs` | The same backup, restore and flash through Tempo Recovery. |
| `packages/tempo_usb/rust/src/firmware.rs` | The write plan, the preloader gate, and the write, verify and resume loop. |
| `packages/tempo_usb/rust/src/restore.rs`, `backup_resume.rs` | Backup staging and validation; the resumable backup directory. |
| `packages/tempo_usb/rust/src/partitions.rs` | Vendor partition discovery from the stock scatter and the observed MBR. |
| `packages/tempo_usb/rust/src/raw_install.rs`, `raw_image.rs` | The guarded BOOTIMG and LOGO path and offline raw-image checks. |
| `packages/tempo_usb/rust/src/da.rs` | `Geometry`, the download agent session, region reads and writes. |
| `toolbox/app/lib/toolbox_controller.dart` | Turns helper events into GUI state, including the preloader acknowledgement. |
| `toolbox/app/lib/engine_native.dart` | File choosers and the calls into `ToolboxOperations`. |
| `toolbox/app/lib/native_advanced_io.dart` | Connection files and the read-only diagnostics card. |
| `toolbox/linux/70-tempo-recovery.rules` | Grants the desktop session access to a player in recovery. |

## Transports

Backup, restore and flash use Tempo Recovery by default. `ToolboxOperations`
puts `recovery` in front of the helper command unless the Legacy Download
Agent is selected, which the GUI exposes under Options, Advanced, Transfer
method, and the browser build requires. The recovery path RAM-boots the player
with `ramboot-DA.bin`, `payload.bin` and `preloader.bin` from the bundle's
`recovery/` directory, waits up to five minutes for a device already running
recovery or a powered-off player, and refuses to continue unless the service
reports the Y2's three region sizes. The `--preloader` option is not passed on
that path; the bundled preloader supplies the memory setup.

The download agent path is used for everything else: connection checks,
`partitions`, `fetch`, backup resume, and raw installation. It waits 30
seconds for a probe and 300 seconds for a storage operation, requires exactly
one MediaTek boot device, vendor `0x0e8d` with product `0x2000`, `0x2001` or
`0x0003`, checks that the hardware code is `0x6582`, loads `DA.img`, and reads
the geometry. Any operation that touches storage stops unless the geometry is
exactly the Y2's: a `0x1d2000000` byte USER area, two 4 MiB boot regions and a
512 KiB RPMB. The `--preloader FILE` option, or Choose BROM preloader in the
GUI, supplies EMI settings for DRAM setup on this path and never enables a
preloader write.

## Inspection

| Operation | Behaviour |
| --- | --- |
| `device list`, `device info`, Check USB connection | Probe the chip and report its hardware code and versions; nothing is loaded and nothing is written. |
| `doctor` | Report where `tempo-usb` and `DA.img` were found without connecting. |
| `partitions`, Connect and read partition map | Load the agent, then read the candidate MBR and EBR1 sectors at three bases and require exactly one base to hold both; report it with the vendor partition table. |
| `fetch NAME OUTPUT`, Export a partition | Read one partition named in the stock scatter, or `boot1` or `boot2`, into a new file, publishing it only after the length and SHA-256 are known. RPMB is never exported. |
| `inspect FILE`, `inspect-raw` | Offline checks of a package or of a BOOTIMG, LOGO or wrapped BOOT1 image. |
| `diagnose` | The SSH support report from a running player; see [Working with a device](../development/device.md). |

The partition map lookup never assumes a scatter base. `locate` derives the
raw shift from the fixed BOOTIMG offset, reads sector zero and the EBR1
sector at `0`, at that shift and at `0x1400000`, and refuses to name a
partition unless exactly one base shows a real MBR and a signed EBR. A fetch
writes to `<output>.partial` first and refuses an output that already exists.

## Backup

A backup is one gzip stream in the `raw-emmc-gzip` layout: BOOT1, BOOT2, a
zeroed 512 KiB RPMB gap, then the USER area, `7827095552` bytes uncompressed.
The output must not exist. Through recovery the three regions are read
straight into the file with a screen context of `Backing up player`; through
the agent the stream goes to `<output>.partial` and is renamed on success. The
GUI suggests `innioasis-y2-<date>-emmc.img.gz` and reads only; nothing on the
player changes. After the read the player is reset unless reboot after success
is off, and a failed reset is reported together with the transfer result.

`backup --resume DIRECTORY` continues an interrupted capture over the agent.
The directory is the `<output>.resume` folder a backup keeps beside its
output, or any directory in the same layout: `backup.json` in the
`tempo-mtk-emmc-1` format, `boot1.img`, `boot2.img` and `emmc-user.img.zst`
holding 64 MiB USER chunks as separate zstd frames. Every saved chunk is
hashed against the sidecar before USB opens, and then compared byte for byte
with the connected player before any missing chunk is read, so a different
device is refused. RPMB is read into `rpmb.img` for the gzip gap only. Once
every chunk is present the directory is assembled into the gzip file. The GUI
and the browser build do not offer resume.

## Restore

`restore INPUT` accepts the gzip image or a legacy backup directory. The gzip
file must start with the gzip magic; the directory must carry the same
`backup.json` sidecar, with `complete` set, matching geometry and a contiguous
chunk list. Before USB opens the whole backup is decompressed into a private
temporary directory as three images, hashed as it is written, and checked
against the sidecar when there is one. The RPMB interval in a gzip image is
consumed and never mapped. Truncated data, trailing data and a bad gzip
checksum all fail here, and staging needs about 8 GB of free space. The result
is an in-memory manifest with three writes, BOOT1, BOOT2 and USER at offset
zero, and from that point restore is a flash. In the GUI a backup is chosen or
dropped on the Restore step; the browser build reports that restore requires
the native Toolbox.

## Flash

`install FILE` and the Flash walkthrough take a `.y2-firmware` package or a
legacy scatter ROM, validated and staged as described in
[Firmware packages](firmware-packages.md). The helper then emits
`firmware-ready`, waits for the device, checks the geometry, and executes the
write plan mapping by mapping. Over the agent each mapping is written in 64 MiB
operations; through recovery each mapping is one transfer with a screen context
such as `Flashing boot` and `Partition 2/5 - write + readback verification`.
Progress events carry the phase, the mapping name, the region and byte counts,
and the GUI shows a per-partition bar plus an overall bar when more than one
mapping is at least 128 MiB.

| Option | CLI | GUI | Effect |
| --- | --- | --- | --- |
| Verify written data | `--no-verify` to disable | Options switch, on by default | Read every written range back and compare it with the source. |
| Skip matching data | `--resume` | Advanced, Write options, native only | Compare each range first and skip it when every byte already matches. |
| Allow preloader flashing | `--allow-preloader` | Advanced, after the acknowledgement dialog | Keep the package's BOOT1 mapping in the plan. |
| Reboot after success | `--no-reboot` to disable | Options switch, on by default | Reset the player when the operation succeeds. |

The GUI confirms a flash or restore in a dialog that names the package, states
whether readback is enabled and whether the preloader is protected. The
finished result reports whether storage was written, whether it was verified,
and whether the player was reset; when every range already matched, the
message says so and nothing was written.

## Readback verification

Verification is on unless it is disabled for the operation. Over the agent the
helper reads each range back after writing it and fails at the first byte that
differs; the transfer total counts each byte twice so progress reflects the
extra read. Through recovery the verify flag makes the service read each chunk
back and compare before acknowledging it, and the host checks every response
against its own completed count. Resume adds a third pass: a range is read and
compared first, a match is reported as `skipped`, and a mismatch is written and
verified as usual. A resume never trusts a saved progress marker, only the
bytes on the chip.

## The BOOT1 and preloader policies

BOOT1 holds the wrapped preloader, and a bad write there can leave the player
unreachable. The policy has four parts, and all of them apply to restore as
well as flash, over either transport.

1. `write_plan` drops every BOOT1 mapping unless preloader flashing is enabled
   for this operation. On the command line that is `--allow-preloader`; in
   the GUI it is the Allow preloader flashing switch, which opens a dialog
   describing the risk and enables only when Enable is chosen. The choice is
   not stored: selecting a task again resets it.
2. When enabled, there must be exactly one BOOT1 mapping, it must start at
   offset zero and cover the full 4 MiB, and its first page must carry the
   `EMMC_BOOT`, `BRLYT` and GFH headers with consistent length fields. A raw
   preloader without its wrapper is refused.
3. The plan is sorted so the BOOT1 write comes last, after every USER and
   BOOT2 write, so a failure in a recoverable region is never followed by a
   preloader write.
4. Through recovery the boot write additionally carries the authorisation
   flag the service requires, and the service lifts `force_ro` only around
   that write. The GUI disables Stop while a BOOT1 write is in progress.

`toolbox dev dist` never puts a BOOT1 mapping in Tempo's own package, and a
legacy scatter import only maps `EMMC_USER` rows. The only inputs that can
carry BOOT1 are Toolbox backups, which is why restore reports that the input
includes a preloader and keeps it protected by default.

## Guarded raw writes

`install-raw BOOTIMG|LOGO FILE SAFETY` is the path for writing a single vendor
partition through the agent. It inspects the image offline, reserves a private
safety file that must not exist, locates the partition through the observed
MBR, reads the current header and refuses a BOOTIMG that lacks `ANDROID!`
unless `--force-boot-header` is given, reads the whole partition into the
safety file and verifies it, and for LOGO also writes a trimmed `.logo.img`
that can be installed directly. The write itself sits behind
`HARDWARE_WRITE_VALIDATED` in `raw_install.rs`, which is `false`, so only
`--dry-run` is accepted and it stops after the safety backup. BOOT1 is never a
raw target; it goes through the package policy above.

## Cancellation and reset

Stop in the GUI and SIGINT on the command line ask the helper to cancel. The
helper finishes the bounded transfer it is in, sends `CANCEL` to the recovery
service or lets the agent command complete, and reports `cancelled`. After a
successful agent operation the player is reset; after a failed flash it is
reset as well, and both messages are combined if the reset also fails. A
recovery transfer ends with `REBOOT`, or with the player left in recovery when
reboot after success is off, or with a warning when the service cannot reboot.
On Linux, `70-tempo-recovery.rules` tags the recovery gadget for the active
session and tells ModemManager to ignore it; the bundle carries the rule beside
the executables for installation into the udev rules directory.
