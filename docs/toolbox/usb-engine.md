# USB engine

Every byte Toolbox exchanges with a Y2 over USB is produced by one Rust
crate, `tempo-installer`, in `packages/tempo_usb/rust`. The crate builds
twice: as the native `tempo-usb` executable that the desktop app and the CLI
run as a child process, and as a Wasm module that the browser build loads
through `wasm-bindgen`. Both carry the same MediaTek preloader handshake,
download agent session, manifest validation and read-back policy. The Dart
package around the crate, `tempo_usb`, owns nothing of the protocol; it
starts and stops the process, or supplies WebUSB, Web Serial and browser
storage to the Wasm module. Tempo Recovery transfers, the vendor-format
backup resume and legacy restores exist only in the native build.

## Components

| Where | What |
| --- | --- |
| `packages/tempo_usb/rust/Cargo.toml` | The `tempo-installer` crate: `cdylib` plus `rlib`, and the `tempo-usb` binary. |
| `packages/tempo_usb/rust/src/lib.rs` | Device candidates, endpoint layout selection, the `Transport` trait and the preloader `probe`. |
| `packages/tempo_usb/rust/src/da.rs` | Parsing `DA.img`, the download agent session, eMMC geometry, bounded reads and writes, reboot. |
| `packages/tempo_usb/rust/src/emi.rs` | The preloader's DRAM table, sent when the boot ROM asks for it. |
| `packages/tempo_usb/rust/src/native.rs` | `NativePort` over `rusb`: opening, claiming, timeouts and the read boundary. |
| `packages/tempo_usb/rust/src/main.rs`, `control.rs` | The `tempo-usb` command line, its JSON event stream and its cancellation channel. |
| `packages/tempo_usb/rust/src/recovery.rs`, `recovery_workflows.rs` | The host client for the recovery bulk service and the backup, restore and flash workflows over it. |
| `packages/tempo_usb/rust/src/firmware.rs`, `package.rs`, `spft.rs` | Manifest validation, the write plan, `.y2-firmware` staging and legacy scatter ROM import. |
| `packages/tempo_usb/rust/src/restore.rs`, `backup_resume.rs`, `partitions.rs`, `raw_image.rs`, `raw_install.rs`, `sparse_image.rs` | Backup import, resumable legacy capture, scatter-based partition discovery and raw image handling. |
| `packages/tempo_usb/rust/src/web.rs` | The `wasm-bindgen` exports and the JavaScript interfaces the module calls back into. |
| `packages/tempo_usb/lib/src/native_engine.dart` | `NativeUsbEngine`: locating and supervising the helper process. |
| `packages/tempo_usb/lib/src/engine_web.dart`, `lib/src/browser/` | The browser `UsbEngine`: sessions, transports, archive parsing and origin-private storage. |
| `packages/toolbox_core/lib/toolbox_core.dart` | `ToolboxOperations`: the argument lists the GUI and CLI hand to the helper. |
| `packages/tempo_build/lib/src/toolbox.dart` | `ToolboxBuildTools`: the cargo, Wasm and `wasm-bindgen` steps of `toolbox dev toolbox build`. |
| `toolbox/app/web/installer.js` | Loads the generated Wasm ES module before Flutter starts. |
| `toolbox/linux/70-tempo-recovery.rules` | The udev rule for the recovery device. |

## Finding and opening the device

A powered-off Y2 enumerates as a MediaTek boot device, vendor `0x0e8d` with
product `0x2000`, `0x2001` or `0x0003`; `is_candidate` accepts exactly
those. A running Tempo, and unrelated MediaTek hardware, are refused.
`select_layout` then walks the configuration and requires exactly one
interface of class `0x0a` or `0xff` with one bulk IN and one bulk OUT
endpoint. It never guesses among several. A single CDC control interface,
class 2 at alternate 0, is recorded so the probe can set the line coding;
more than one is an error.

`NativePort::open` accepts only devices with one configuration, retries an
access failure for one second because Linux publishes the node before udev
has applied its rules, asks libusb to detach and reattach kernel drivers,
selects the configuration if needed and claims the data and control
interfaces. Serial string descriptors are not requested during capture, so
the boot window is spent on the handshake. Reads request up to 1 MiB rounded
to the endpoint packet size and buffer any surplus for the next call.

Timeouts are deliberate. The preloader handshake runs with a 500 ms transfer
timeout; once the download agent is up the workflows raise it to ten seconds,
because eMMC operations may pause that long between responses. A DA read is
a transaction: `begin_read_transaction` sets a twenty second absolute
deadline, and a read that does not finish with its checksum acknowledged
marks the port unsynchronised, after which no further command, including the
reboot, is sent. The stdin cancellation flag is ignored inside a transaction
so a cancel never leaves a half-read command on the wire.

## The preloader probe

`probe` first sets the CDC line coding to 921600 baud, 8N1, and asserts RTS
when a control interface exists. It then sends the synchronisation sequence
`a0 0a 50 05`, expecting each byte's complement back. The Y2 can queue ASCII
`READY` banners before answering; the probe consumes them, resends `a0` once
after the first banner with a 25 ms pause for the preloader's poll interval,
and gives up after 64 banners or 32 attempts. `GET_HW_CODE` and
`GET_HW_SW_VER` follow. The report carries the hardware code, version and
subcode, and `compatible_chip` is true for `0x6582`. `y2_verified` stays
false until the download agent reports the eMMC geometry.

## The download agent session

`Agent::parse` reads the entry table of `DA.img` at offset `0x6c`, one
`0xdc`-byte entry per chip, and picks the single entry whose chip, version
and subcode match the probe. The entry must have three regions, with the
first stage at `0x200000` and the second at `0x80000000`; any other layout
is refused. `initialize_with_emi` then runs the vendor session in order:

1. Security query `0xd8`; an authenticated agent is not supported.
2. `0xd7` uploads the first stage in 1 KiB pieces and checks the XOR checksum.
3. `0xd5` jumps to it; the agent answers `0xc0`, its NAND and eMMC identifiers, and version `4 2 87`.
4. The SPFT configuration block for the Y2 is sent, with battery mode on auto-detect.
5. If DRAM initialisation reports `0xbc3`, `emi.rs` sends the EMI table extracted from a preloader image. That table must be `MTK_BLOADER_INFO_v12`; without a preloader the session fails with a message asking for `--preloader`.
6. The second stage is uploaded in 4 KiB blocks, each acknowledged with `0x5a`.
7. The agent reports its storage records, from which `Geometry` takes the boot1, boot2, RPMB and user sizes.

`Geometry::is_y2` requires a user area of `0x1d2000000`, two `0x400000`
boot areas and an `0x80000` RPMB. Every workflow stops when this fails.

Reads use command `0xd6` in 1 MiB chunks against the agent's continuous
address space, where boot1, boot2, RPMB and the user area follow one another;
`read_hardware_region` translates a physical region and offset into that
space. Each chunk ends with a 16-bit additive checksum and an acknowledgement.
Writes use the generic eMMC command `0x62` with the same alignment checks:
partition 1, 2 or 8, 512-byte alignment, and a range inside the capacity the
session itself reported. `reboot` arms the agent's watchdog for three
seconds, which is how SPFT restarts a player.

The same session RAM-boots Tempo Recovery: `boot_ram_with_progress` keeps the
vendor first stage for DRAM setup and substitutes the recovery payload as the
second stage with a zero signature length. See
[Tempo Recovery](../platform/recovery.md) for the payload and the device side.

## The helper process

`tempo-usb` is one process per operation. It prints one JSON object per line
on stdout and diagnostics on stderr, exits 1 on an error and 2 on a usage
error. The first argument selects the operation:

| Arguments | Operation |
| --- | --- |
| `probe [wait-seconds]` | Handshake and chip report; waits 30 seconds by default, at most 300. |
| `recovery probe`, `recovery backup FILE`, `recovery restore FILE`, `recovery flash FILE` | The recovery workflows, with `--allow-preloader`, `--resume`, `--no-verify` and `--no-reboot`. |
| `backup DA-file OUT.img.gz` | Legacy agent backup, captured in 64 MiB chunks into `OUT.img.gz.resume` beside the output and published as one gzip stream when complete. |
| `backup-resume DA-file LEGACY-DIR OUT.gz` | Resume a vendor-format capture from its `backup.json` sidecar. |
| `restore DA-file BACKUP [--allow-preloader]`, `flash DA-file PACKAGE [--allow-preloader]` | Stage and hash the input, then write with read-back. `--resume` compares first and `--no-verify` skips read-back. |
| `inspect-firmware PACKAGE`, `prepare-firmware PACKAGE [DIR]`, `prepare-spft ROM [DIR]`, `preview-spft ROM` | Offline package and scatter ROM handling without USB. |
| `partitions DA-file`, `fetch DA-file PARTITION FILE`, `read-sample`, `backup-sample`, `map-sample` | Read-only diagnostics over the legacy agent. |
| `inspect-raw`, `flash-raw` | Raw `BOOTIMG` and `LOGO` handling; writes stay disabled by `HARDWARE_WRITE_VALIDATED`. |

`--preloader FILE` supplies the EMI table for the boot ROM path and is
dropped for `recovery` commands, whose payload bundle carries its own
`preloader.bin`. DA operations wait up to 300 seconds for a device, and the
wait starts only after staging, which may itself take minutes. Firmware and
backups are hashed against their manifests before the device is opened, so a
bad package never reaches the wire.

Cancellation is cooperative. A control thread reads stdin and sets the flag
only on a complete `cancel` line; EOF is not a cancel, so a CLI run without
stdin behaves normally. On Unix, SIGTERM and SIGINT set the same flag.
Workflows clear the flag after the transfer so the reboot can still be
issued, and a failed reset is reported beside the transfer error rather than
hidden by it.

`NativeUsbEngine` is the Dart side of that contract. It finds the executable
through `TEMPO_USB_ENGINE`, beside the running Toolbox binary, or under
`build/toolbox/rust/release`, and `DA.img` through `TEMPO_USB_AGENT`, beside
the executable, or at `platform/firmware/DA.img`. It runs one operation at a
time, forwards events to the caller and keeps `result`, `error`,
`firmware-info` and `raw-image-info` as the terminal event. `stop` writes
`cancel`, waits thirty seconds, then escalates to SIGTERM and SIGKILL with
two second graces, and holds the operation slot until both pipes have
drained. `ToolboxOperations` in `toolbox_core` composes the argument lists
above; it prefixes `recovery` unless the legacy download agent was chosen.

## Recovery from the host side

`UsbBulk::open` looks for vendor `0x0525`, product `0xa4aa`, and an
interface of class `0xff`, subclass `0x54`, protocol 1 with one bulk
endpoint each way. It requires exactly one such device and reports the udev
rule in its error when the open is denied. Bulk transfers move 64 KiB at a
time with a thirty second timeout.

`Client` frames every command with the 48-byte `TEMPREC1` header, checks the
response opcode, size and CRC-32, and turns a non-zero status into an error. `info` records whether the service supports
`CONTEXT`, `FILL` and `REBOOT`, so an older recovery build degrades to plain
writes and a manual restart. `set_context` limits the title to 63 printable
bytes and the detail to 95. Transfers send `FILL` for a chunk that repeats
one four-byte pattern, sample throughput for progress, and send `CANCEL` on
any error or when the cancellation flag is raised. The frame layout and the
service's own rules are in [Tempo Recovery](../platform/recovery.md).

`recovery_workflows::connect` locates `ramboot-DA.bin`, `payload.bin` and
`preloader.bin` in `recovery/` beside the executable or in `build/recovery`
up the working directory, and waits up to five minutes for either a running
recovery or a powered-off Y2 to RAM-boot. `geometry` checks the three
region sizes against the Y2 before any transfer. Backups write boot0, boot1,
a zeroed RPMB gap and the user area into one gzip stream at the fast
compression level; restores and flashes build the write plan, order the
preloader last, and require exactly one preloader mapping with a valid
header.

## The Wasm build

`web.rs` compiles only for `wasm32`, where the recovery, package, restore
and native modules are absent. It exports six functions: `usb_layout`,
`inspect_firmware`, `verify_firmware`, `probe_usb`, `backup_usb` and
`flash_usb`. The module never touches a `USBDevice` itself; it calls back
into JavaScript objects the Dart side constructs: a port with `read`,
`write`, `control` and `resumeForReset`, a backup sink with `start` and
`writeChunk`, a firmware source with `readChunk`, and a flash observer with
`progress`. `backup_usb` and `flash_usb` run the same probe, agent session
and geometry check as the native build, then read or write through those
callbacks, and reboot afterwards when asked. Only the legacy download agent
is available in a browser; the `UsbEngine` refuses recovery transfers,
restores and backup resume with a message pointing at the desktop Toolbox.

`ToolboxBuildTools.buildWasm` runs `cargo build --locked --release --lib
--target wasm32-unknown-unknown` in the
[toolchain container](../platform/toolchain.md), then `wasm-bindgen --target web` into
`toolbox/app/web/pkg` and writes a `package.json` marking the output as an ES
module. The container installs `wasm-bindgen-cli` 0.2.122, and `Cargo.toml`
pins the `wasm-bindgen` crate to exactly that version, because the two must
match. `toolbox dev toolbox build web` copies `DA.img` into
`toolbox/app/web` and runs `flutter build web --no-web-resources-cdn`.
`installer.js` imports `./pkg/tempo_installer.js`, initialises it, stores
the promise as `window.tempoUsbWasmReady`, and only then imports
`flutter_bootstrap.js`.

## The browser adapter

`UsbEngine.initialize` refuses Firefox and insecure contexts, awaits the
Wasm promise, fetches `DA.img`, and creates two `BrowserSession`s, one over
`navigator.usb` and one over `navigator.serial`. A session asks for
permission with filters for the three MediaTek products, keeps the user
activation by calling the picker before any other await, and reacts to
`connect` and `disconnect` events; `watch` waits thirty seconds for an
already-authorised device to reappear. A device whose transfer timed out is
retired until it is physically reconnected.

`BrowserPort` maps `read`, `write` and `control` onto `transferIn`,
`transferOut` and `controlTransferOut`, with a 500 ms timeout during the
handshake and ten seconds during an operation, and reads at most 64 KiB per
call. `SerialTransport` opens the port at 921600 baud with RTS asserted and
DTR clear, keeps the operating system's CDC driver, and rejects raw control
requests. The endpoint layout is still chosen by Rust: the session
serialises the interfaces it sees and passes them to `usb_layout`.

Firmware packages are read by `archive.dart`, a strict ZIP and ZIP64 parser
that keeps only the central directory in memory, rejects encryption,
symlinks, unsafe names, overlapping entries and any prefix before the first
local header, and requires `manifest.json` first and at most 1 MiB.
`FirmwareDestination` streams each image into origin-private storage under
`tempo-firmware-<timestamp>`, refuses to start when the quota is below the
total plus 64 MiB, and hashes the staged files with `verify_firmware`
before the device picker opens. `BackupDestination` names the output
`innioasis-y2-<date>-emmc.img.gz`, compresses through `CompressionStream`,
and writes into origin-private storage when about 7.9 GB is free, offering
the file as a download afterwards; otherwise it asks for a save location
through `showSaveFilePicker`.

## The Linux udev rule

```
SUBSYSTEM=="usb", ATTR{idVendor}=="0525", ATTR{idProduct}=="a4aa", ATTR{serial}=="tempo-recovery", TAG+="uaccess", ENV{ID_MM_DEVICE_IGNORE}="1"
```

The rule matches the recovery gadget by vendor, product and serial, tags it
for the active desktop session so the helper can open it without root, and
tells ModemManager to leave the ACM console alone. The native build copies
it beside `tempo-usb` in the CLI directory and in every GUI bundle; it is
installed into `/etc/udev/rules.d`, followed by a rules reload and a
reconnect. The MediaTek boot device is not covered by the rule.

## Checks

`toolbox dev toolbox check` runs `cargo fmt --check`, `cargo test --locked`
and `cargo clippy --all-targets -- -D warnings` on the crate, builds the
Wasm module, and runs the `browser_*` tests in `packages/tempo_usb/test`
with `dart test -p node` using the container's own Dart SDK. See [Testing and checks](../development/testing.md).
