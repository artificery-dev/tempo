# Storage and profiles

Tempo keeps two kinds of data for the person using the player. The Tempo
profile is what the app itself owns: `settings.json`, the wallpaper and the
applet state files, all under the XDG directories of the account the player
runs as. The Cadence datastore is the media library's SQLite database and
artwork cache, and it is the only thing that can live on the SD card instead
of internal storage. Which location holds the datastore is a bootstrap
decision made by `tempod` before the library opens, recorded in a small
selector file by the `tempo_data` package, and changed only through a service
restart. This page follows that decision from the selector to the screens
that drive it, and then through the eject and format flows the same screens
run. The library daemon's side is in
[Cadence integration](cadence-integration.md) and
[Cadence supervision](../daemon/cadence.md).

## Components

| Where | What |
| --- | --- |
| `packages/tempo_data/lib/tempo_data.dart` | `TempoStorageManager`: the selector, pending requests, startup resolution and the copy backend; `TempoProfilePaths`, `TempoStorageDecision`, `TempoStorageRequest` and the `TempoDatastoreMover` interface. |
| `daemon/lib/src/services/storage_host.dart` | `StorageHost`: owns one resolved profile per daemon lifetime, answers status, stages selections and queues the restart. `queueStorageRestart` runs `systemctl`. |
| `daemon/lib/src/services/profile_access.dart` | `ensureProfileAccess`: ownership, modes and access verification of the active data and config roots. |
| `daemon/lib/src/services/cadence_datastore_mover.dart` | The `TempoDatastoreMover` that prepares and executes a Cadence relocation. |
| `daemon/bin/tempod.dart` | Profile mode: builds the manager from `--profile-home`, `--sd-root` and the device monitor, then starts `cadenced` on the resolved datastore. |
| `daemon/lib/src/transports/http/player_server.dart` | `GET` and `POST /api/v1/storage`, `POST /api/v1/storage/card`. |
| `packages/player_api/lib/src/storage.dart` | `StorageStatus` and `StorageSelection`, the JSON both ends agree on. |
| `packages/daemon_client/lib/src/storage_client.dart` | `StorageClient`: status, select, dismiss, retry and card maintenance calls. |
| `app/lib/src/daemon_data_storage.dart`, `daemon_card_maintenance.dart` | The device implementations of the two controllers below, over `StorageClient`. |
| `packages/tempo_core/lib/src/services/data_storage.dart`, `card_maintenance.dart` | `DataStorageController` and `CardMaintenanceController`, the interfaces the screens use and the emulator mocks. |
| `packages/tempo_core/lib/src/settings/data_storage_screen.dart` | The insert prompt, the Tempo Data Location screen and the recovery app. |
| `packages/tempo_core/lib/src/settings/sd_eject_screen.dart`, `sd_format_screen.dart` | Eject SD Card and Format SD Card. |
| `packages/tempo_core/lib/src/settings/library_folders_screen.dart` | Library Folders and its folder browser. |
| `packages/tempo_core/lib/src/storage/places.dart`, `mounted_file_system.dart`, `mounted_entities.dart` | `Places`, the XDG paths and browsing roots; `MountedFileSystem`, one namespace with a card mounted inside it. |

## Two kinds of data

`Places` in `tempo_core` names the directories the app reads and writes. On
the device `DevicePlaces` builds it from the environment of the player
account, and `DaemonApp` then replaces `home` and `config` with what `tempod`
reports in its storage status.

| Data | Path | Owner |
| --- | --- | --- |
| `settings.json` | `Places.config`, which is `$XDG_CONFIG_HOME/tempo` or `<home>/.config/tempo` | Written by `tempod`'s `SettingsHost` on the device, by the app in the emulator. See [Settings system](settings.md). |
| `wallpaper.<ext>` | `Places.config` | The app. |
| `applets/<id>.json` | `Places.data`, which is `$XDG_DATA_HOME/tempo` or `<home>/.local/share/tempo` | The app, through `AppletStore`. |
| Cadence datastore | `<home>/.cadence` or `<card>/.cadence` | `cadenced`, started by `tempod`. |
| Storage selector | `<home>/.local/state/tempo/storage-selector.json` | `tempo_data`, through `tempod`. |

`TempoProfilePaths.device` pairs `<home>/.cadence` with `<configHome>/tempo`;
`TempoProfilePaths.sd` pairs `<card>/.cadence` with the same device config
directory. The config root never moves, so settings and wallpaper keep working
when the card is absent, and `StorageStatus.configPath` is always the internal
path. The manager refuses overlapping roots and refuses a selector inside any
profile root. Media folders are not part of either profile: `mediaHome` is
reported separately and the library roots are a setting, described below.

## The selector and the policy

The selector is one JSON object, written to `<path>.new` with a flush and
renamed into place:

```json
{"version": 1, "policy": "yes", "requestId": "…"}
```

`policy` is one of `yes`, `no` and `ask`; a missing file reads as `ask`.
`resolveStartup` turns the policy and the hardware into a decision:

| Field | Value |
| --- | --- |
| `location` | `sd` only when the policy is `yes`, the card root is mounted and `<card>/.cadence` exists; otherwise `device`. |
| `activePaths` | The SD paths in that case, else the device paths. |
| `needsPrompt` | The policy is not `no`, the location is not `sd`, and a card is mounted. |
| `sdAvailable` | A card is mounted. |

A card root counts as mounted only when the caller passes one. `tempod`
passes `--sd-root`, by default `/mnt/sd`, as `cardRoot` only while the
device monitor reports a card mounted at that exact path, so an empty mountpoint
directory never selects the card. Two more files sit beside the selector:
`storage-selector.json.pending` holds a queued request, and
`storage-selector.json.transaction` is the copy backend's journal.

## Profile mode in tempod

`TEMPOD_PROFILE_HOME` or `--profile-home` turns profile mode on. The staging
drop-in sets it to `/home/<user.name>` together with `TEMPOD_PROFILE_USER`
and `TEMPOD_SD_ROOT=/mnt/sd`; the config home is `$XDG_CONFIG_HOME` or
`<home>/.config`. Without profile mode `tempod` only owns the file named by
`--settings-file` and starts no library. The options are listed in
[tempod](daemon.md) and [Configuration reference](../reference/configuration.md).

At startup `StorageHost.initialize` calls `applyPendingAtStartup`, which runs
before any settings or database owner opens. If the resolved profile is
available, `ensureProfileAccess` walks the data and config roots, refuses
symlinks in or above them, assigns them to the profile user with `0700` and
`0600` modes, and verifies as that user with `runuser` that everything is
readable and writable; FAT volumes may reject the mode changes, so the
verification is what decides. Then `cadenced` starts with `--store` set to
the data path and `--store-kind directory` for internal or `mount` for the
card. A library failure at this point is logged and the daemon carries on
without a library, because the Tempo profile is still usable.

The manager's `checkpoint` hook runs `sync -f` on the selector's directory at
every phase, so the selection is on disk before ownership of the datastore
changes hands.

## Status and selection over HTTP

`GET /api/v1/storage` returns a `StorageStatus`:

| Field | Meaning |
| --- | --- |
| `policy`, `location` | The selector policy and the resolved location. |
| `available` | Startup succeeded and the active paths exist. |
| `mediaHome`, `dataPath`, `configPath` | The media home, the datastore path when available, and the internal config path. |
| `sdAvailable`, `sdProfileExists`, `deviceProfileExists` | A card is mounted; `<card>/.cadence` exists; the internal data or config root exists. |
| `needsPrompt` | The startup question should be asked, and has not been dismissed this lifetime. |
| `restartPending` | A pending request file exists. |
| `error` | The startup or restart error text, or a generic message when the selected profile is unavailable. |

`POST /api/v1/storage` takes a `StorageSelection` of `policy`,
`adoptExisting` and `replaceExisting`, or one of the two single-key bodies
`{"retry": true}` and `{"dismissOffer": true}`. A selection that only changes
the preference, meaning the profile is internal and the new policy is not
`yes`, or the profile is on the card and the policy is unchanged, rewrites the
selector and answers 200. Anything else is staged with `prepareRequest` and
answered 202 with `restartPending` true; 250 ms later the host runs
`systemctl --no-block restart tempod.service tempo.service`. If that fails the
pending request is cleared and the error is reported in the next status.
Conflicts answer 409 with `profile_conflict` or `storage_unavailable`.

`DaemonDataStorage` in the app polls the status every two seconds and maps it
onto `DataStorageStatus`: `cardPresent` is `sdAvailable`, `usingCard` is the
location, `restarting` is `restartPending`, and a failed poll keeps the last
reading because a queued restart briefly removes the listener. Before every
change it awaits `beforeChange`, which `TempoApp` sets to stop playback and
video, flush applet state and the settings file, and pause settings writes
until the status settles again.

## The startup prompt

`TempoApp` watches the controller. When the status is available, not busy,
the policy is not `no`, `promptAvailable` is set and a card is present, it
pushes `DataStoragePrompt` once per card; removing the card arms the question
for the next one. The dialog is titled `SD Card Inserted` and offers `Use
card` and `Use device` on a wheel rail. Its text changes when
`cardProfileExists`: a card that already holds a `.cadence` is offered as a
library to use, otherwise the question is whether the library data should
travel with the card. Either way no media files move.

| Choice | Request |
| --- | --- |
| Use card | `policy: yes`, with `adoptExisting` when the card already has a datastore. |
| Use device, back or menu | `policy: no`. |

The `DataStorageController` interface also carries `adoptCardForStartup`,
which selects `yes` with adoption, and `skipStartup`, which posts
`dismissOffer` so the daemon stops reporting `needsPrompt` until its next
start without touching the selector.

## Tempo Data Location

The settings screen shows the preferred location, `Internal` when the policy
is `no` and otherwise `External`, then the location in use, and two buttons,
`Internal` and `External`. `External` is disabled without a card. Choosing
the location already in use only changes the preference. Choosing the other
one asks first:

- `Move library data to the SD card?` or `Move library data to internal
  storage?`, with `Cancel` and `Move data`. The move is Cadence's relocation,
  described in [Cadence integration](cadence-integration.md#moving-the-datastore).
- When the destination already holds a datastore, `Saved media library data
  already exists.` with `Use existing`, `Move current data` and `Cancel`.
  `Use existing` sends `adoptExisting`; `Move current data` sends a plain
  move and is disabled while the profile is unavailable.

On the device `prepareRequest` runs with the Cadence mover. `replaceExisting`
is refused outright, because an active datastore cannot be overwritten.
Adoption requires `library.sqlite` at the destination and records no
relocation. A move requires a mounted card and asks the mover to prepare; the
request is persisted with a random sixteen byte id and its relocation intent.
The emulator constructs the manager without a mover and uses the package's
own copy backend: an existing destination needs `adoptExisting` or
`replaceExisting`, adoption inventories the tree and rejects symlinks,
replacement swaps only the `library.db` files, and the copy is staged in a
`.stage-<id>` sibling, hashed into the journal and renamed into place with a
`.backup-<id>` kept until the selector commits.

## Applying a request at restart

`applyPendingAtStartup` runs first in the new `tempod`. A pending request
whose id the selector already carries is discarded as done. Otherwise, with
the Cadence mover, a request that carries a relocation is marked `started`
and executed; a rejection Cadence proves safe, `TempoDatastoreMoveRejected`,
deletes the request and the daemon opens the unchanged source with the
message in `error`. Any other failure leaves the request in place. On
success the selector takes the requested policy and the request file is
removed. A started request can no longer be cleared or replaced through the
API.

When the selector says `yes` and a different card identity is observed later
in the lifetime, `observeCard` queues the same restart so the library reopens
on the card that is actually present, unless a request is already pending.

## The recovery screen

`DaemonApp` shows `DataStorageRecoveryApp` instead of the player when the
status is not available. It creates no player, library or settings; it hosts
`DataStorageChoices` over the storage controller, with the same wheel
handling as the settings screen.

| Condition | Screen |
| --- | --- |
| A request is pending and the controller is retryable | `Finish moving your media library`, with the startup error and a `Retry move` button that posts `{"retry": true}`; the daemon restarts services after the same delay and the move resumes with its original intent. |
| Otherwise | `Choose available storage`, with `Internal` and `External`. A selection here may replace an unstarted pending request, since the host passes `replacePending` while a startup error stands. |

Two startup failures block selection until services restart with the right
card: a started move that fails for any other reason, reported as `Library
move is incomplete`, and a copy-backend journal that cannot be finished,
reported as `Profile recovery is incomplete`.

## Ejecting the card

Eject SD Card asks `Stop playback and safely eject the SD card?`.
`DaemonCardMaintenance.eject` refreshes the Cadence volume status, takes the
current device snapshot as the target, and requires a datastore id, a
generation, a card mount id and a card id; without a card it fails with
`Insert an SD card before ejecting it`. It then blocks library playback,
stops audio and video, and posts `action: eject` with those four identifiers
to `/api/v1/storage/card`, with a two minute timeout. `CardHost` quiesces
Cadence and unmounts the card as described in
[Cadence integration](cadence-integration.md#eject-resume-and-format).

| Phase | Screen |
| --- | --- |
| `ejecting` | `Finishing library work and ejecting…` |
| `ejected` | `You can now remove the SD card.` and a `Close` button. |
| `failed` | `The card could not be ejected. Keep it inserted.` with `Retry eject` and `Resume library`. |

After a successful eject the controller keeps the target. When the device
readings later report a card mount id different from the ejected one, it
resumes automatically with `action: resume`, then calls
`resumeAfterHostMaintenance` on the library. `Resume library` does the same by
hand after a failure. While maintenance is busy or has failed, the card
activity indicator stays lit, because `DaemonApp` counts both as media
activity.

## Formatting the card

Format SD Card is available only while the profile is available, internal,
not busy and not restarting; otherwise it says `Switch Tempo Data Location to
Internal before formatting.` The button reads `Format SD card`, then `Erase
and format` after the first press, and the text warns that all files and
partitions are erased. The screen calls `format` on the maintenance
controller, which follows the eject path with `action: format`, expects the
`formatted` state, and resumes the library. The result reads `SD card
formatted as exFAT.`

## Library folders and places

Library Folders lists the sections alphabetically and, inside each, `Add
Folder`, `Use Default Folders`, `Scan Libraries` and one `Remove` row per
configured root. The browser starts at the library's `locations` and walks
directories only. Choices are saved as `/settings/library/roots`, a map from
section name to folder paths, and handed to the library's `configureFolders`;
the daemon's coordinator reads the same setting, as described in
[Cadence integration](cadence-integration.md#library-sections-and-roots).

`Place` names the browsing roots: `home`, `sdCard` and `root`, the last
offered only while `FullFilesystem.enabled` is on. The emulator serves the
same shape through `MountedFileSystem`, one namespace that resolves each path
against the longest mount prefixing it, refuses renames across mounts, and
checks that a path under a mounted host folder does not escape it through a
symlink.
