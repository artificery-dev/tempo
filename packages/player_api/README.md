# Player API

Pure-Dart commands, state snapshots, and the `PlayerService` interface shared by
Tempo's player and its control transports. This package depends on neither
Flutter nor Relic.

`PlayerCommand.fromJson` validates commands before execution.
`PlayerSnapshot.fromJson` and `toJson` define the state contract.
`PlayerService` provides a synchronous current snapshot, broadcast snapshot
updates, and asynchronous command execution. The playback owner serializes
mutations and increments the revision before notifying subscribers.

Snapshots are complete state, not individual durable events. Adapters may
coalesce them for slow consumers. Revisions are scoped to a service session;
new connections obtain a fresh snapshot rather than assuming replay across
restarts. A real player service has one owner regardless of how many HTTP,
WebSocket, local-socket, or future D-Bus clients connect.

`UnavailablePlayer` is the startup backend until the player connects. It
reports availability truthfully and fails commands with `player_unavailable`.

## App–daemon events

Each event has its own class/file and supports `toJson()` and
`PlayerEvent.fromJson()`. The version 1 envelope carries `type` and `sessionId`.
These types can be emitted by either process; their roles follow the playback
owner, which is initially the Flutter app.

| Event | Purpose |
| --- | --- |
| `PlayerCommandRequested` | Ask the owner to execute a validated command; includes `requestId` |
| `PlayerCommandSucceeded` | Reply with the same `requestId` and resulting full snapshot |
| `PlayerCommandFailed` | Reply with the same `requestId` and a safe `PlayerFailure` |
| `PlayerSnapshotEmitted` | Publish initial state or a state/availability change |
| `PlayerSyncRequested` | Ask the known owner session to publish a fresh snapshot |

The owner chooses a new nonempty session ID when its service starts. Connection
setup must establish that session before commands are sent; these messages do
not implement discovery or authentication. Requesters choose nonempty request
IDs unique within the session. Replies echo both IDs. Receivers must reject
commands for a stale session and ignore stale replies; revision comparisons
are valid only within the same session. Reconnect obtains a fresh snapshot.
Availability is carried by `state.available`, avoiding a separate conflicting
availability state. A transport disconnect must also make a proxy unavailable,
even if the owner could not emit a final snapshot.

Only unsolicited snapshots may be coalesced. Command requests and replies must
be delivered individually or failed explicitly. There is no durable replay or
exactly-once guarantee: do not automatically retry a command with an unknown
outcome (especially `toggle`, `next`, or `previous`).

These are message contracts, not a connected app–daemon transport. The existing
REST/WebSocket API and `PlayerService.changes` remain unchanged. Transport
adapters own authentication, pending-request tracking, timeouts, backpressure,
and cleanup. Unknown versions/types or malformed required payloads produce a
`FormatException`; extra envelope fields are ignored for additive changes.
