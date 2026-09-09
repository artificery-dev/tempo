# Tempo profile storage

Pure Dart over `package:file`. This package has no Flutter, SQLite, mount,
platform-channel or process integration. Filesystem paths use the supplied
filesystem's namespace.

- Device data: `<home>/.tempo`; config: `<XDG config home>/tempo`.
- SD data: `<card>/.tempo`; config: `<card>/.tempo/config`.
- Selector: a caller-supplied device-local file outside both profiles. The default
  is `<home>/.local/state/tempo/storage-selector.json`.

Media home/card roots remain independent. Profile copy includes the owned data
and config trees (library database, applets, settings and wallpaper), never media
outside those trees. Symlinks are rejected. The selector and its journal/pending
files are not copied.

## Policy

`TempoStoragePolicy` has `yes`, `no`, `ask`; absent selector means `ask` with the
device profile active. Ask offers the startup prompt only when an existing SD
profile is available. Dialog Yes explicitly adopts that profile and selects yes;
No leaves ask unchanged for the next startup; Don't Ask Again selects no.
Selected SD that is unavailable yields **null activePaths**, never a stale device
fallback. The host must determine actual mount presence: a bare mountpoint
folder is insufficient evidence. Supply `cardRoot: null` when absent.

Existing destinations require explicit adoption or `replaceExisting: true`.
Adoption preserves their bytes. Copying a new SD profile copies the device data
and config; copying back moves SD config to the separate device config root.
Sources are retained. A switch back cannot silently adopt an old device profile.
The caller presents the adoption/replacement choice before setting those flags.

## Daemon integration

Construct `TempoStorageManager` with `fs`, `devicePaths`, `selectorPath` and the
currently mounted `cardRoot`. At startup, **after all old database/profile owners
have stopped**, call `applyPendingAtStartup()`. It recovers any interrupted
publication, applies queued intent and returns `TempoStorageDecision` with
`policy`, `location`, `activePaths`, `needsPrompt` and `sdAvailable`.

While running, call `prepareRequest(TempoStorageRequest(policy: ...))`, then
queue the service/UI restart. Preparation checks routing and destination
collisions and persists intent only: it never reads database bytes or copies a
profile. On restart-queue failure use `clearPendingRequest()`. An unstarted
pending request may be explicitly superseded with `replacePending: true`; a
started migration cannot be discarded through that path. `readSelector()` and
`readPendingRequest()` are read-only status APIs. Do not call `resolveStartup()`
or `recover()` from a live status endpoint; they may complete a migration.

Direct `switchToSd`, `switchToDevice`, `acceptExistingSd` and `setPolicy` are
available to already-quiesced callers. `switchToDevice(policy: ask)` returns to
the device while retaining the startup-question policy. Settings must not use
raw `setPolicy(yes)` as a substitute for first-time profile copy/adoption.

## Recovery limits

The single-owner coordinator uses flushed files, hash inventories, sibling
staging directories and rename publication. It journals both device roots,
retains replacement backups until the selector commits, and recognizes a
completed request on retry. Incomplete preparation is discarded; corrupted
prepared data is refused with source/backups retained. File contents are copied
and hashed in bounded chunks. Every caller must close/checkpoint SQLite first.

The abstraction has no portable directory fsync. These are tested process-crash
recovery semantics, not a claim of power-loss durability on every filesystem.
Actual SD removal, read-only device filesystems and platform execution still
require integration testing; MemoryFileSystem tests inject write failure and
exercise both POSIX and Windows path namespaces.
