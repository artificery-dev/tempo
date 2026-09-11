# Tempo Recovery

Recovery runs a dedicated kernel and built-in initramfs. Toolbox can boot it in
RAM through the Download Agent and includes a packaged recovery image in Tempo
firmware. Booting recovery does not write or mount storage; explicit host
operations use the USB transfer service.

## Build and use

Native desktop and CLI Toolbox builds automatically build Recovery when its
inputs or packaged outputs change. To build it explicitly, run from the
repository root:

```sh
dart run toolbox/cli/bin/toolbox.dart dev os recovery build
```

The toolchain container builds and tests the service and display. Generated
files live under `build/recovery/`: `payload.bin` and `ramboot-DA.bin` are a
matched RAM-boot pair; `recovery.img` is the separate LK-format storage image.
The vendor preloader supplies DRAM configuration during RAM boot and is not
flashed by that operation. Physical-button entry into the installed recovery
image has not been implemented.

Use Toolbox's Backup & Restore workflow for backup, restore, and flashing.
Tempo Recovery is the default transfer method; the Advanced options expose the
Legacy Download Agent. Verification and reboot-after-success are normal options.
A running recovery connects directly; a powered-off player is first booted into
RAM. Do not run concurrent host USB operations against one player.

## Service and display

The USB manufacturer is `Tempo`, product `Recovery`, and serial `tempo-recovery`.
A vendor bulk interface (class/subclass/protocol `ff/54/01`) carries transfers;
a separate ACM interface provides the diagnostic console. The device exposes
USER, BOOT0, and BOOT1; writes require aligned, bounded, unmounted ranges and
explicit boot-region authorization. The service synchronizes writes and restores
read-only protection when a session ends. Transport failures trigger USB
re-enumeration so the host can reconnect; interrupted writes are not replayed
automatically.

The Rust client lives in `packages/tempo_usb/rust/src/recovery.rs`; workflow and
package handling live alongside it. The C service is `transfer.c`. Both ends
check CRC-32 and acknowledge completed I/O. Android sparse RAW/FILL/DONT_CARE
handling and readback policy belong to the host workflow. Mobile USB permissions
and Windows driver installation remain platform validation work.

`ui.c` reads atomic updates from `/run/tempo-recovery-state`. The record contains
mode, percentage, title, detail, then completed bytes, total bytes, monotonic
sample time and bytes per second. A detail containing ` - ` splits into two
lines, giving three status lines. Known totals show a progress bar, percentage,
byte counts and speed. Unknown totals and preparation/stopping phases use a
spinner. Idle displays **Recovery Ready**.

`test-status.py` covers status parsing and rendering; `test-transfer.py` covers
the protocol using temporary files; `test-charge-policy.c` covers the recovery
charging policy. The current kernel and recovery sources preserve the tested
hardware implementation; historical bring-up journals are maintained separately.
