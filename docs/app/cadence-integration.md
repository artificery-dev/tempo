# Cadence integration checkpoint

Tempo is transitioning from the embedded `cadence_media` service to the standalone
`cadenced` daemon and its wire-only `cadence_client`. The device composition now supervises `cadenced` from `tempod`, and the UI uses
the Cadence client for browsing and media-path resolution. Confirmed datastore
relocation and the combined safe-eject UI remain integration work; the hardware
eject primitive is implemented and tested separately.

## Ownership and storage

- Tempo preferences, wallpaper, and other device state remain in internal XDG storage.
- Cadence metadata has exactly two Tempo locations: `$HOME/.cadence/` or
  `/mnt/sd/.cadence/`. Internal mode does not put it in XDG.
- Datastore location and media root are independent. A datastore declares its
  media root; item paths remain relative to that root. For example,
  `$HOME/.cadence` may declare `/mnt/sd` while the media stays on the card.
- In the declared-root setting, `.` means the directory containing `.cadence`.
  Thus `/mnt/sd/.cadence` with root `.` resolves media beneath `/mnt/sd`, while
  `$HOME/.cadence` with root `.` resolves home media when there is no SD card.
- Switching Internal/External asks whether to move the database and cache.
  A confirmed move preserves IDs and media files, changing the root reference
  from `/mnt/sd` to `.` when moving onto that card, or back when moving home.
  If the media is actually under home, moving metadata to the card must preserve
  that home media root instead of retargeting it to the card. Cadence owns this
  operation; Tempo must not rewrite its tables or move the media files.
- An SD media root requires the actual SD mount even when its datastore is
  internal. An empty mountpoint directory must never stand in for a card.
- Pre-release database conversion and legacy root inference are not supported.
  Tempo settings and app state remain internal and are not part of the datastore.
- The UI resolves library UUID + item ID through Cadence. Returned paths are valid
  only for that datastore ID and attachment generation, and are never persisted.

## Eject contract

Tempo gates new playback and closes decoder/file handles before calling
`ejectVolume(expectedId:, expectedGeneration:)`. Cadence rejects new work, drains
jobs, closes SQLite, flushes the volume, and releases its mount lease. Only a matching
`detached` response with `readyToUnmount` permits Tempo's hardware step.

The tempod `eject-sd` operation flushes `/mnt/sd` and performs a **normal** unmount.
Busy mounts and flush failures are errors, never grounds for forced or lazy detach.
The automount service stops only after normal unmount succeeds. Playback remains
blocked after failure; retry retains the original identity, and resume is explicit.
Formatting and hardware eject share an exclusive maintenance lock.

Cadence activity events contain complete status. Use them directly and poll
`GET /volume` when needed; fetching `/snapshot` in response to every activity event
would create more activity. Combine Cadence requests/jobs/artwork/draining with
Tempo playback and kernel I/O for the eventual card-use indicator. Unknown is not
idle, and idle is not a guarantee of safe removal.

## Headless root availability

`CadenceRoots` translates `DeviceSnapshot` into complete root-availability snapshots
for either metadata location, using its declared media root and mount policy. Device observations expose the kernel mount ID and
verified physical SD CID independently. The bridge never treats the mount directory
as proof of availability. A missing CID means unknown source identity and full
revalidation by Cadence.

Availability acknowledgments rotate Cadence's generation. The bridge caches the
acknowledged generation and hardware signature to avoid repeated root updates on
idle polling. Requested eject suppresses SD roots through the unmounted state;
only explicit resume or a new kernel mount releases suppression. Its contract tests
cover these cases, incomplete mount observations, and stale snapshots.

Cadence and the hardware bridge must share the Linux mount namespace because
mountinfo IDs are namespace-specific. Tempo's existing units do not create private
mount namespaces; the supervised Cadence child preserves this arrangement.
The bridge is connected to the production daemon composition.

## ARM validation, 2026-09-09

Current ARM bundle source checkpoint: `e2aae399c88a7704efe739211045aa61f728e023`.
An isolated source archive was built; the Cadence checkout was not modified.

- Dart SDK **3.13.2**, pinned for daemon builds, produces a direct ARM32
  `bundle/bin/cadenced` and ARM SQLite asset with `dart build cli`.
- The toolchain container now pins Rust **1.92.0** and builds `cadence-probe`
  for `armv7-unknown-linux-gnueabihf` with the GNU ARM linker.
- `tempo dev cadence build` builds the bundle and records source revision and
  file hashes. Rootfs staging verifies those hashes and ARM ELF headers before
  installing it. The local source archive is an integration input pending
  publication of the Cadence source repository.
- ARM probe dependencies are `libc.so.6`, `libm.so.6`, `libgcc_s.so.1`, and
  `ld-linux-armhf.so.3`. The supervisor sets `CADENCE_PROBE_PATH` to the bundle.

The physical Y2 passed isolated ARM scans and resolution for home metadata/home
media, home metadata/card media, and card metadata/card media at checkpoint
`6b0b0f6`. The native probe read the tagged FLAC fixture, and a separate process
read the resolved path with the expected SHA-256. Eject/reattach rejected stale
generations; an unchanged scan found no changed items. Scratch mounts used tmpfs
and were normally unmounted afterward.

At `07d9bb8`, the newly built tempod supervised cadenced on the physical Y2 using
private sockets and scratch metadata. The six libraries, completed availability
handshake, and clean parent/child shutdown passed. Existing Tempo services stayed
running. A fresh-profile XDG ancestor ownership issue found during this test is
fixed and covered by a host test.

These checks do **not** establish exFAT surprise-removal/power-loss behavior,
UI playback handle release during card maintenance, confirmed datastore moves,
or acceptance of the final firmware package. Those remain integration work.

### Relocation checkpoint

The `bae3d78` ARM bundle passed an additional physical-Y2 test with scratch home
metadata and a tmpfs card mount. A forward move to the card and reverse move home
preserved datastore, library and item IDs. The declared root changed between the
absolute card path and `.`, while media bytes resolved identically. Replaying
both completed operations with their original IDs returned matching acknowledgements.
Both daemon owners stopped before each move and the scratch mount was removed.

Tempo's relocation launcher requires a matching final `relocation-complete`
record **and** process exit zero. It rejects retargeted media, mismatched IDs,
missing completion, and failed exits even if an `activated` progress event was
seen. Six subprocess tests pass. The production storage selector now uses this launcher. It persists consent and
stable card identity before restart, flushes its filesystem before ownership
changes, reacquires the current mount ID after reboot, and commits selection only
after acknowledgement. Started intents cannot be discarded or replaced. The
recovery screen retries the original operation. Six selector/host tests and ten
storage UI tests pass.

Destination-conflict preflight/cancel-safe error handling, safe-eject UI, and
card-removal fallback still require integration. The embedded emulator continues
to use its own media implementation and the manager's original copy backend;
production tempod explicitly installs the Cadence mover instead.

### Removal and rejected moves

Card removal no longer restarts the frontend or makes its internal settings
profile unavailable. Cadence transport failures invalidate media references;
collection polling can recover under a new generation without rebuilding the UI.
The interface can also start when Cadence is unavailable, with collection errors
reported separately from settings. Unit coverage verifies this boundary; actual
surprise removal on the device remains an acceptance check.

A relocation error may cancel its intent only when Cadence explicitly reports
`cancelSafe: true`, `retryWithSameOperationId: false`, and exits with its failure
code. Missing/contradictory output preserves the pending intent. Safe rejection
reopens the unchanged source with the error available to the UI. The e2aae39 ARM
bundle includes this contract; it has built successfully. Host/subprocess tests
cover both outcomes. Advisory preflight is available from Cadence but not yet
used by Tempo; actual move validation remains authoritative.
