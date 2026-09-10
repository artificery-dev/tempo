# Cadence supervision

`tempod` is the only process that starts, stops, configures or moves the
media library daemon, `cadenced`. The Dart daemon holds five classes for
that job, each with one responsibility: `CadenceProcess` owns the child,
`CadenceRoots` tells it which roots the hardware currently offers,
`CadenceCoordinator` keeps the library sections and their folders in line
with settings, `CardHost` quiesces it before the card is unmounted or
formatted, and `CadenceDatastoreMover` with `CadenceRelocation` runs the
offline move between internal storage and the card. This page is about
those classes and the order they run in. The contract they implement, the
datastore locations, the path rules and the eject requirements, is in
[Cadence integration](../app/cadence-integration.md).

## Components

| Where | What |
| --- | --- |
| `daemon/bin/tempod.dart` | Wires the classes together at startup and tears them down in order. |
| `daemon/lib/src/services/cadence_process.dart` | `CadenceProcess`: spawn through `setpriv`, wait for the socket, stop with SIGTERM then SIGKILL. |
| `daemon/lib/src/services/cadence_roots.dart` | `CadenceRoots`: serialized root availability updates, card quiesce and resume. |
| `daemon/lib/src/services/cadence_coordinator.dart` | `CadenceCoordinator`: sections, roots from settings, the boot scan, the two second poll. |
| `daemon/lib/src/services/card_host.dart` | `CardHost`: `POST /api/v1/storage/card` eject, resume and format. |
| `daemon/lib/src/services/storage_host.dart` | `StorageHost`: the profile selector, pending moves and service restarts. |
| `daemon/lib/src/services/cadence_datastore_mover.dart` | `CadenceDatastoreMover`: the `TempoDatastoreMover` the storage manager calls. |
| `daemon/lib/src/services/cadence_relocation.dart` | `CadenceRelocation`: the `cadenced relocate` invocation and its event protocol. |
| `daemon/lib/src/services/device_monitor.dart` | `DeviceMonitor`: the `DeviceSnapshot` every class above reads. |

## Startup order

`tempod.dart` builds the library services only when a profile home is
configured, which the rootfs drop-in does with `TEMPOD_PROFILE_HOME`. The
sequence is:

1. `DeviceMonitor` starts and is refreshed once synchronously, so the card
   observation exists before any decision depends on it.
2. `StorageHost.initialize` resolves the profile through
   `TempoStorageManager`, applying or recovering any pending move. The
   manager only receives `cardRoot` when the monitor reports the card mounted
   at the SD root; an empty directory is not a card. The manager's
   `checkpoint` runs `sync -f` on the selector's directory before ownership
   crosses a datastore boundary.
3. If the profile resolved, `ensureProfileAccess` fixes ownership for the
   profile user, and the store path and kind are taken from it: `mount` for
   a card profile, `directory` otherwise.
4. `CadenceProcess.start` launches `cadenced` for that store. When the store
   holds no `library.sqlite`, `--initialize` and the media root arguments
   are added as the integration page describes.
5. `CadenceRoots` and `CadenceCoordinator` are built on the process's
   client; `coordinator.start` runs with the settings file's current
   contents.
6. `CardHost` is built, and two listeners are attached: a device change
   whose `cardMountId` differs from the last observed one calls
   `coordinator.observeCard`, and every settings change calls
   `coordinator.configure`.

Any failure from step 4 onward is a library failure, not a profile
failure. The daemon logs `Media library unavailable`, closes whatever was
built, and continues without Cadence so settings, wallpaper and the rest of
the API keep working. At shutdown that state makes the process call `exit`
explicitly after cleanup rather than waiting on anything still pending.

## CadenceProcess

`start` prepares the socket directory, `chown`s it to the profile user and
group and `chmod`s it `700`, then spawns
`setpriv --reuid=<user> --regid=<gid> --init-groups <executable> --socket <path> ...`
with `CADENCE_PROBE_PATH` pointing at `lib/libcadence_probe.so` next to the
bundle's `bin/`. Both output streams are line-split into the daemon's log.
It then polls `volumeStatus` every 100 ms through a `UnixMediaTransport`
with a two second request timeout, for up to twenty seconds. An exit during
that wait, or the deadline, closes the process and rethrows.

The exit future is watched for the whole lifetime. An exit that was not
requested calls `onUnexpectedExit`, which in `tempod.dart` sets the exit
code to 1 and completes the stop future, so the daemon shuts down and
systemd restarts `tempod.service`. `close` closes the client, sends SIGTERM
if the child is still running, waits twenty seconds for exit 0, and on
timeout sends SIGKILL and logs that storage must not be moved in this
lifetime.

## CadenceRoots

Every method queues on one serial future, so two observations can never
send interleaved availability updates. `synchronize` is the common path:

1. If the card mount is suppressed by an earlier eject request but the
   observed mount ID is a new one, lift the suppression; a new mount is a
   new card as far as suppression is concerned.
2. Read the volume declaration. When an expected ID or generation was
   given and does not match, fail. When the state is not `attached`,
   return it unchanged.
3. Require `pathStyle` of `volume-posix`.
4. Compute a signature from the volume ID and generation, the card path,
   mount ID and source ID, and the suppressed mounts. If it equals the last
   accepted one and Cadence already reports root availability ready,
   return without sending anything.
5. Read the root snapshot and check its volume is still the same. Every
   root's `mountPath` must equal the declared `mediaMount`. A root with no
   mount path is always available. A root on the card is available only
   when the mount is not suppressed, the observed card path equals it, and a
   mount ID is present; available card roots carry the mount ID and CID.
6. `setRootAvailability` with the expected ID and generation, require the
   same ID back with availability ready, and record the signature.

`quiesceCard` marks the card mount suppressed, remembering the mount ID it
saw. For a `portable` datastore it calls `ejectVolume` and requires a
`detached` reply for the same ID and generation with `readyToUnmount`. For
a `local` one it forces a synchronize, which now sends the card roots as
unavailable, and requires `storageKind` `local` and the card path among
the quiescent mounts. `resumeCard` reattaches a detached portable volume
with `attachVolume`, clears the suppression, and forces a synchronize.

## CadenceCoordinator

`start` stores the settings, queues `_configure`, then arms two timers: a
periodic one every two seconds that queues `roots.synchronize`, and a
single eight second one that queues a scan of every section unless
`/settings/library/scan-on-boot` is false. All work goes through one serial
queue whose errors are logged as `Cadence policy:` and never break the
queue.

`_configure` returns at once unless the volume is `attached`, then requires
an absolute `resolvedMediaRoot`. Media counts as available when there is no
`mediaMount` or the monitor sees that mount with a mount ID. For each of the
six sections it finds or creates the library, then computes the wanted
roots: the validated absolute paths from `/settings/library/roots` when the
user configured that section, else `/<Name>` if that directory exists under
the media root and the media is available. Existing roots are deleted only
when a configured list exists and omits them; missing media never removes a
root. Wanted roots not yet known are posted. Finally it synchronizes
availability. `observeCard` is `_configure` again; reconciliation after the
media returns is Cadence's job, not the coordinator's. `_scan` synchronizes
first and treats HTTP 409 from a section as a scan already running.

## CardHost

`execute` accepts exactly the fields `action`, `datastoreId`, `generation`,
`mountId` and `cardId`, all non-empty strings, with `action` one of
`eject`, `resume` or `format`, and refuses to run two operations at once.
It then:

1. Refreshes the monitor. An `eject` for an identity it already ejected,
   with no card mounted, answers `ejected` again.
2. Checks that the card at `/mnt/sd` still has the requested mount ID and
   CID, and that Cadence's volume still has the requested ID and generation.
3. For `resume`, calls `roots.resumeCard` and answers `resumed`.
4. For `format`, requires `storageKind` `local`; a datastore on the card
   must be moved internal first.
5. Calls `roots.quiesceCard` with the expected identity, refreshes and
   checks the card again.
6. For `format`, runs `tempo-system format-sd <cardId>`, refreshes, resumes
   the roots and answers `formatted`. Otherwise runs
   `tempo-system eject-sd <mountId>`, remembers the identity, refreshes and
   answers `ejected`.

Both helpers live at `/usr/local/lib/tempo-system/tempo-system` and
re-verify the identity they were given. What they do to the block device
is in [Storage](../porting/storage.md).

## Relocation

Moving the datastore is never done while `cadenced` or the player is
running. The pieces run in this order across two daemon lifetimes.

In the first lifetime, `StorageHost.select` receives a storage selection
from `POST /api/v1/storage`. A change that only alters the selector's
policy is written directly. Anything else calls
`TempoStorageManager.prepareRequest`, which asks
`CadenceDatastoreMover.prepare` for the intent. `prepare` requires an
attached volume of the opposite kind to the destination, an observed card
with path, mount ID and CID, and that the card side of the move is exactly
`<cardPath>/.cadence`, re-reading the monitor to confirm the card did not
change meanwhile. The intent it returns is the `CadenceRelocation` fields
plus `toCard`, `cardPath` and `cardSourceId`, and the manager persists it.
250 ms after replying, `StorageHost` runs
`systemctl --no-block restart tempod.service tempo.service`. Both stop jobs
precede both start jobs, so the player and this daemon are down before
anything opens the datastore again.

In the next lifetime, `StorageHost.initialize` calls
`applyPendingAtStartup` before any owner opens. That calls
`CadenceDatastoreMover.execute`, which requires the same card path and CID
to be mounted now, binds the operation to the current mount ID on whichever
side is the card, and runs `CadenceRelocation.run`. That spawns
`setpriv ... cadenced relocate` with the source and destination paths and
kinds, the mount IDs, the operation ID and the expected datastore ID.
`stdout` must be a sequence of JSON events carrying that operation ID:
`relocation-progress`, at most one `relocation-error`, or one
`relocation-complete` whose `state`, `datastoreId`, `store`, `storageKind`,
`resolvedMediaRoot`, `sourceRetired` and `sourceRetained` all match the
request. There is no timeout; success needs both streams closed, exit 0 and
a matching completion.

A failure is `CadenceRelocationFailure`. It is `cancelSafe` only when the
exit code is 75, the protocol was clean, Cadence reported the error with
`cancelSafe` true and `retryWithSameOperationId` false; the mover turns that
into `TempoDatastoreMoveRejected`, and `StorageHost` resolves the old
profile and records the message. Any other failure keeps the operation
pending under the same ID: `StorageHost` marks recovery blocked, reports
that the original card must be reinserted, and refuses further selections
until a restart succeeds. `retryPending` schedules that restart on request.

`StorageHost.observeCard` also restarts the services when the card identity
changes while the policy is `yes` and no move is pending, so a card profile
reopens on the card that arrived.

## Shutdown

`tempod.dart` closes services in a fixed order: the HTTP server first so no
new work arrives, then storage, the Bluetooth player, the playback owner,
the device monitor, the coordinator, `cadenced`, settings, and last the
native library if one was loaded. `CadenceCoordinator.close` cancels its
timers, drains its queue and closes `CadenceRoots`, which waits for its
serial future. `CadenceProcess.close` follows, so Cadence receives no
availability update after it has been asked to stop. An incomplete cleanup
or a failed library owner exits with status 1 after flushing stderr rather
than waiting for systemd's kill.
