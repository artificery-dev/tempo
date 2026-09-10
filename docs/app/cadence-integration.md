# Cadence integration

Tempo's media library is Cadence, a separate project at
<https://git.artificery.dev/artificery/cadence>. Its daemon, `cadenced`, owns
filesystem scanning, the SQLite database, job execution and artwork generation.
Tempo never opens the library database itself. It talks to `cadenced` over a
Unix socket through the `cadence_client` package, and `tempod` decides when the
daemon runs, which datastore it opens, and which library roots are reachable
given the hardware state.

## Components

| Where | What |
| --- | --- |
| `config.yaml` `cadence:` | The release tag and bundle checksum Tempo installs. |
| `packages/tempo_build/lib/src/cadence.dart` | `toolbox dev cadence fetch`: downloads the armhf bundle from that release, checks the tarball checksum and the bundle's own manifest, and unpacks it under `build/os/cadence/arm/bundle`. |
| `packages/tempo_build/lib/src/rootfs.dart` | Verifies the bundle again and installs it into the image at `/usr/local/lib/cadenced/`, with `/usr/local/sbin/cadenced` linked to its binary. |
| `daemon/lib/src/services/cadence_process.dart` | `CadenceProcess`: starts and stops the daemon. |
| `daemon/lib/src/services/cadence_coordinator.dart` | `CadenceCoordinator`: creates the library sections and configures their roots from settings. |
| `daemon/lib/src/services/cadence_roots.dart` | `CadenceRoots`: tells Cadence which roots are available given the mounted card. |
| `daemon/lib/src/services/card_host.dart` | `CardHost`: eject, resume and format of the SD card, behind `/api/v1/storage/card`. |
| `daemon/lib/src/services/cadence_relocation.dart`, `cadence_datastore_mover.dart` | Moving the datastore between internal storage and the card. |
| `packages/tempo_core/lib/src/services/cadence_library.dart` | `CadenceLibrary`: the player's attachment boundary and path resolution. |
| `packages/tempo_core/lib/src/services/cadence_media_library.dart` | The emulator's library, built on the `cadence_media` package rather than a daemon. |

`cadence_client` is a git dependency of `app`, `daemon` and `tempo_core`.
`tempo_core` also depends on `cadence_media`, which only the Toolbox emulator
uses; the device never loads it.

## Process supervision

`tempod` starts `cadenced` as a child through `setpriv`, so the daemon runs as
the profile user (`tempo` by default) while `tempod` stays root. `setpriv`
execs in place, which means the supervised PID is `cadenced` itself. The socket
lives at `/run/cadenced/media.sock` in a directory owned by that user with mode
`0700`. `CADENCE_PROBE_PATH` points the daemon at its bundled native probe
library. Startup waits up to twenty seconds for the socket to answer a volume
status request; if the process exits first, startup fails.

The daemon's stdout and stderr are forwarded to `tempod`'s log. An unexpected
exit makes `tempod` exit with status 1 so systemd restarts the whole service
group. A normal stop sends SIGTERM and waits twenty seconds for a clean exit; a
timeout escalates to SIGKILL and is logged as a reason not to move storage in
the same lifetime. The environment variables `CADENCE_SOCKET` and
`CADENCED_EXECUTABLE` override the socket path and binary for development.

## Datastore and media root

Cadence metadata lives in exactly one of two places, chosen by the storage
selector in `tempo_data`:

- `$HOME/.cadence` when the profile is internal (`--store-kind directory`)
- `/mnt/sd/.cadence` when the profile is on the card (`--store-kind mount`)

Tempo settings, wallpaper and other app state stay in internal XDG directories
regardless; only the library moves.

The datastore is separate from the media root. A datastore declares where its
media lives, and item paths are relative to that root. When `tempod` finds no
`library.sqlite` in the store it passes `--initialize` with a media root of
either `.` (the directory holding `.cadence`) or the card mountpoint:

| Store | Card mounted | Media root |
| --- | --- | --- |
| internal | no | `.` (media under home) |
| internal | yes | `/mnt/sd`, with `--media-mount /mnt/sd` |
| card | yes | `.` (media under the card) |

An SD media root is only usable while the actual card is mounted. `tempod`
passes `cardRoot` to the storage manager only when the device monitor reports a
card at `/mnt/sd`; an empty mountpoint directory never counts as a card.

`CadenceRoots` requires Cadence's `volume-posix` path style, so every path the
player receives is relative to the declared root.

## Library sections and roots

`CadenceCoordinator` maintains six libraries and creates any that are missing:

| Key | Name | Cadence type |
| --- | --- | --- |
| `music` | Music | `music` |
| `podcasts` | Podcasts | `podcasts` |
| `recordings` | Recordings | `music` |
| `audiobooks` | Audiobooks | `books` |
| `shows` | Shows | `shows` |
| `movies` | Movies | `videos` |

Each library's roots come from the `/settings/library/roots` setting. When the
user has configured folders for a section, those absolute, normalised paths are
the complete root set and anything else is deleted. When they have not, the
coordinator adds `/<Name>` if that directory exists under the media root and
the media is currently available, and never removes anything. Missing media
therefore never drops a root; only an explicit folder setting can.

The coordinator reconfigures on every settings change and whenever the card
mount ID changes. It polls root availability every two seconds, which also
catches a restarted daemon. Eight seconds after startup it asks Cadence to scan
every library unless `/settings/library/scan-on-boot` is false; a scan already
in progress (HTTP 409) is not an error.

## Root availability

Cadence does not inspect mounts itself. `CadenceRoots` translates the daemon's
`DeviceSnapshot` into a root availability update: a root on a removable mount
is available only when the observed card path matches, the kernel mount ID is
present, and the mount is not suppressed by a requested eject. Available roots
carry the mount ID and the card's physical CID so Cadence can tell a reinserted
card from a different one; a missing CID means unknown identity and full
revalidation.

Updates are serialised and skipped when nothing has changed, keyed on the
volume ID and generation, the card path, mount ID, source ID and the
suppression set. Each acknowledgement rotates Cadence's generation. Every update
checks that the volume ID and generation have not changed underneath it and
that each root's mount path matches the declared media mount.

Cadence and `tempod` must share a Linux mount namespace, because mountinfo IDs
are namespace-specific. Tempo's units do not create private namespaces, and the
supervised child inherits its parent's.

## Path resolution in the player

`CadenceLibrary` in `tempo_core` is the only place the player obtains media
paths. It resolves a library UUID plus item ID through Cadence and treats the
result as valid only for the current datastore ID and attachment generation.
Paths are never composed from the mountpoint and never persisted. When the
transport fails, existing references are invalidated and collection polling
recovers under the new generation without rebuilding the UI. The player also
starts when Cadence is unavailable, reporting collection errors separately from
settings.

`cadenceBusy` reads Cadence's activity counters (active read and write
requests, running and queued jobs, draining, artwork in progress). It feeds the
card activity indicator together with playback and kernel I/O. It is never a
safe-to-remove signal: unknown counts as busy, and idle is not a guarantee.

## Eject, resume and format

The player's Settings screens call `/api/v1/storage/card` with an action and
the identity it observed: datastore ID, generation, mount ID and card ID.
`CardHost` refuses concurrent operations and re-reads the device state before
and after each step, failing if the card at `/mnt/sd` is no longer the one the
request named or the library generation has moved.

For **eject** the UI stops decoders and closes file handles first. `CardHost`
then quiesces Cadence through `CadenceRoots`:

- If the datastore itself is on the card, it calls `ejectVolume` and requires a
  `detached` response for the same ID and generation with `readyToUnmount`.
- If the datastore is internal, it forces a root update with the card's roots
  unavailable and requires Cadence to report the mount quiescent.

Only then does it run `tempo-system eject-sd <mountId>`. That helper, built
from `platform/rootfs/tool/sd_ejector.dart`, confirms the mount ID still
matches, refuses if the card has any other mounts or `/mnt/sd` holds something
other than the card, syncs the filesystem, and performs a normal `umount`. Busy
mounts and writeback errors are failures; lazy and forced unmounts are never
used for a user eject. The unit's own `ExecStop` uses lazy unmount for surprise
removal only. A repeated eject of the same card after success is a no-op.

Requested eject suppresses the card's roots until either **resume**, which
re-attaches a card datastore if needed and clears the suppression, or a
genuinely new kernel mount of the card.

**Format** is allowed only while the datastore is internal. It quiesces the
same way, runs `tempo-system format-sd <cardId>`, then resumes. Formatting and
eject share the maintenance lock.

## Moving the datastore

Switching data storage between Internal and External in Settings asks whether
to move the library. The move is Cadence's `relocate` command, not a copy Tempo
performs, and it preserves datastore, library and item IDs while changing the
declared media root between the card path and `.`. Media files are never
moved, and media that actually lives under home keeps its home root.

The flow is owned by `StorageHost` and `tempo_data`'s `TempoStorageManager`,
with `CadenceDatastoreMover` as the backend:

1. **Prepare** checks that the active volume is attached and of the kind being
   moved away from, that an identified card is mounted, and that the source or
   destination is that card's `.cadence`. It records the operation ID, the
   datastore ID, both paths, the media root, and the card's path and CID.
2. `tempod` syncs the filesystem holding the selector, persists the intent, and
   restarts the player services. Started intents cannot be discarded or
   replaced.
3. **Execute** runs at the next startup, before any datastore owner opens. It
   requires the same card (by CID) to be mounted and binds the move to the
   current mount ID, since mount IDs change across reboots. It then runs
   `cadenced relocate` as the profile user and reads its JSON event stream.

`CadenceRelocation` accepts the result only when the process exits zero, the
streams close, and a `relocation-complete` event arrived for the same operation
ID with the expected datastore ID, destination, storage kind and media root,
and with the source both retired and retained. There is no timeout. Any other
outcome raises a failure. It is *cancel-safe* only when Cadence exited with
code 75 and reported `cancelSafe: true` and `retryWithSameOperationId: false`;
then the selector reopens the unchanged source and the UI shows the error.
Otherwise the intent stays pending and the recovery screen retries the same
operation. The emulator uses `tempo_data`'s built-in copy backend instead.
