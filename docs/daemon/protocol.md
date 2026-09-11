# Event protocol and HTTP transport

The frontend and `tempod` share one contract, defined without Flutter or
Relic in `packages/player_api`: a `PlayerCommand`, a `PlayerSnapshot`, the
`PlayerService` interface and five events that carry commands and snapshots
between a playback owner and whoever wants to drive it. The Dart host exposes
that contract, together with device, settings, radio and storage services, on
an authenticated HTTP and WebSocket API at `http://127.0.0.1:8765/api/v1`.
The frontend is the playback owner; it attaches on the owner WebSocket and
executes commands the daemon relays from controllers. Every other client,
including the BlueZ player inside the daemon, sees playback through the
daemon's `RemotePlayer` proxy.

## Components

| Where | What |
| --- | --- |
| `packages/player_api/lib/src/player_command.dart` | `PlayerCommand.fromJson`: the eight actions and their validation. |
| `packages/player_api/lib/src/player_snapshot.dart` | `PlayerSnapshot`: the full state object and its JSON form. |
| `packages/player_api/lib/src/player_service.dart`, `unavailable_player.dart` | The owner interface and the truthful startup backend. |
| `packages/player_api/lib/src/events/` | `PlayerEvent.fromJson` and one class per event type. |
| `packages/player_api/lib/src/storage.dart` | `StorageStatus` and `StorageSelection`. |
| `daemon/lib/src/transports/http/player_server.dart` | `PlayerServer`: the Relic router, authentication, body limits and error mapping. |
| `daemon/lib/src/transports/http/event_client.dart` | One `/api/v1/events` subscriber with acknowledged, coalesced snapshots. |
| `daemon/lib/src/transports/http/owner_connection.dart` | The single `/api/v1/owner` connection and its sync timer. |
| `daemon/lib/src/services/remote_player.dart` | `RemotePlayer`: the proxy that turns owner events into a `PlayerService`. |
| `daemon/lib/src/demo_player.dart` | `DemoPlayer`: the `--demo-player` backend with one silent track. |
| `packages/daemon_client/lib/src/playback_owner_connection.dart` | The frontend's side of the owner connection, with reconnect. |
| `packages/daemon_client/lib/src/device_client.dart`, `settings_client.dart`, `radio_client.dart`, `storage_client.dart` | The frontend's HTTP clients. |

## Authentication and origins

Every request is checked before a body is read or a socket upgraded. The
`Authorization: Bearer <token>` header is compared to the expected token in
constant time. `/api/v1/owner` expects the owner token and every other route
the API token; a missing header or a wrong token answers 401 `unauthorized`,
and the owner route answers 404 when the daemon has no owner credential at
all. Tokens are never accepted in URLs.

A request carrying an `Origin` header is refused with 403 `origin_denied`
unless that exact origin was passed with `--allow-origin`. This is an origin
gate for native clients and development pages, not CORS: browsers cannot set
the `Authorization` header on a WebSocket, so a browser UI would need a
session mechanism the daemon does not have.

## Routes

| Route | Service | Purpose |
| --- | --- | --- |
| `GET /api/v1/player` | always | The current `PlayerSnapshot`. |
| `POST /api/v1/commands` | always | Execute one command; the reply carries the resulting `state`. |
| `GET /api/v1/events` | always | WebSocket of full snapshots, at most 16 subscribers. |
| `GET /api/v1/owner` | owner token | WebSocket for the single playback owner. |
| `GET /api/v1/device` | `DeviceMonitor` | Battery and SD card observations. |
| `GET`, `PUT /api/v1/settings` | `SettingsHost` | Read or replace the settings object. |
| `POST /api/v1/radios` | `--radios` | Typed Wi-Fi and Bluetooth operations. |
| `GET`, `POST /api/v1/storage` | profile mode | Profile status and selection. |
| `POST /api/v1/storage/card` | Cadence | Eject, resume and format of the card. |

A route whose service is not configured answers 503 with
`device_unavailable`, `settings_unavailable`, `radio_unavailable`,
`storage_unavailable` or `card_unavailable`. Anything else is 404
`not_found`. The library itself is not behind this API: the frontend talks
to `cadenced` directly on `/run/cadenced/media.sock`, as described in
[Cadence integration](../app/cadence-integration.md).

Responses are JSON with `Cache-Control: no-store` and
`X-Content-Type-Options: nosniff`. Errors take one shape:

```json
{"error":{"code":"invalid_request","message":"Invalid JSON or command fields."}}
```

Request bodies must be `application/json`, else 415
`unsupported_media_type`; are limited to 64 KiB, else 413 `body_too_large`;
and must arrive within five seconds, else 408 `request_timeout`. A
`PlayerFailure` from the player maps to 503 when its code is
`player_unavailable` and to 409 otherwise. Any other exception is logged and
answered as 500 `internal_error` without detail. While the server is closing
every request answers 503 `shutting_down`.

## Commands and snapshots

A command is an object with a `type` and, for two of them, one value.
Unknown types, extra fields and out of range values are rejected with 400.

| `type` | Field | Constraint |
| --- | --- | --- |
| `play`, `pause`, `stop`, `toggle`, `next`, `previous` | none | |
| `seek` | `positionMs` | integer, at least 0 |
| `setVolume` | `volume` | finite number from 0 to 1 |

```sh
curl -H "Authorization: Bearer $TEMPOD_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"type":"play"}' http://127.0.0.1:8765/api/v1/commands
```

A snapshot is the complete state, never a delta:

```json
{"revision":3,"available":true,"status":"playing","trackId":"cadence:42","title":"Song",
 "artist":null,"album":null,"hasNext":false,"positionMs":1200,"durationMs":180000,"volume":1.0}
```

`status` is `stopped`, `paused` or `playing`. `artist`, `album` and `hasNext`
are optional on the wire and default to null and false. `revision` increases
within one daemon session and must not be compared across restarts; a new
connection always starts from a fresh snapshot. Until an owner attaches the
snapshot reports `available: false` and commands fail with
`player_unavailable`. The demo player answers `next` and `previous` with
`unsupported_command`.

## The events WebSocket

`GET /api/v1/events` with `Upgrade: websocket` subscribes a controller to
snapshots. The first message is the current snapshot, and every later state
change is a new one:

```json
{"type":"snapshot","state":{"revision":0,"available":false,"status":"stopped","trackId":null,"title":null,"artist":null,"album":null,"hasNext":false,"positionMs":0,"durationMs":0,"volume":1.0}}
```

The client answers each snapshot with `{"type":"ack","revision":N}`. The
daemon keeps at most one unacknowledged snapshot per client and one pending
replacement; intermediate states are dropped in favour of the newest, so a
slow reader receives the latest state without an unbounded queue. An
acknowledgement must arrive within 15 seconds. Pings run every ten seconds
and messages are capped at 64 KiB in both directions.

| Close code | Meaning |
| --- | --- |
| 4001 | The daemon is stopping. |
| 4002 | A malformed, binary or unexpected message. |
| 4003 | The server or owner slot is unavailable. |
| 4004 | The player service's stream failed. |
| 4008 | The acknowledgement deadline passed. |
| 4009 | A message exceeded the size limit. |

## The owner connection

`GET /api/v1/owner` upgrades to the one playback-owner WebSocket; a second
attempt while one is attached answers 409 `owner_connected`. Both directions
carry `PlayerEvent` objects, each with `version: 1`, a `type` and the owner's
`sessionId`. Unknown versions and types are rejected; extra envelope fields
are ignored so the envelope can grow.

| `type` | Direction | Payload |
| --- | --- | --- |
| `snapshotEmitted` | owner to daemon | `state`, the owner's current snapshot. |
| `syncRequested` | daemon to owner | none; asks for a fresh `snapshotEmitted`. |
| `commandRequested` | daemon to owner | `requestId` and a `command`. |
| `commandSucceeded` | owner to daemon | the same `requestId` and the resulting `state`. |
| `commandFailed` | owner to daemon | the same `requestId` and `error` with `code` and `message`. |
| `bluetoothPlaybackReady` | daemon to owner | `stateRevision` and `active`; private, see [Radio hosting](radios.md). |

The owner chooses a fresh random session ID each time its process starts and
the first message must be a `snapshotEmitted`, within five seconds of the
upgrade. Every later event must carry that session ID or the connection is
closed. After each snapshot the daemon waits one second, sends
`syncRequested` and arms a five second deadline; a missed deadline closes the
connection. This bounds unsolicited traffic to one sync in flight with no
second playback engine. The owner also pushes a snapshot on its own whenever
`status` or `available` changes, so a pause and resume between two polls is
not lost; position-only changes wait for the next poll.

`RemotePlayer` republishes each adopted snapshot under its own revision
counter, which keeps increasing across owner reconnects within one daemon
lifetime, and ignores owner snapshots whose revision does not advance. One
command is outstanding at a time: a second controller request while one is
pending fails with `player_busy`. A command without a reply after ten seconds
fails with `command_timeout`, and the slot stays occupied until the owner
replies or disconnects, because the outcome is unknown and `toggle`, `next`
and `previous` must not be retried blindly. When the connection drops the
proxy publishes `available: false`, fails the pending command with
`player_unavailable` and closes with 4003.

On the frontend, `PlaybackOwnerConnection` connects with the owner token,
sends its snapshot, answers `syncRequested`, executes `commandRequested`
serially through the app's `PlayerService`, and reports any non-`PlayerFailure`
exception as `command_failed`. After a loss it reconnects two seconds later
with the same session ID and never replays a command.

## Device, settings, radios and storage

`GET /api/v1/device` returns the monitor's latest reading, refreshed once a
second: `batteryPercent`, `charging`, `cardPath`, `cardMountId`,
`cardSourceId` and `cardIoBusy`, with null for anything not observed. The
frontend's `DeviceClient` polls it and turns any failure into an unknown
reading rather than reading sysfs itself.

`GET /api/v1/settings` returns the stored object, or `{}` before the first
write. `PUT` replaces it whole: the daemon sorts the keys, refuses more than
64 KiB, writes a temporary file, flushes, renames it over `settings.json`,
and only then answers `{"saved":true}`. Writes are serialized and drained at
shutdown. See [Settings system](../app/settings.md).

`POST /api/v1/radios` takes `{"operation": ..., ...}` with the fields each
operation allows:

| `operation` | Fields |
| --- | --- |
| `refresh` | `scan` |
| `wifi.enable`, `bluetooth.enable` | `enabled` |
| `wifi.join` | `ssid`, `password` |
| `wifi.disconnect` | none |
| `wifi.forget` | `ssid` |
| `bluetooth.connect`, `bluetooth.disconnect`, `bluetooth.forget` | `address` |

Fields are validated before any command runs, one operation runs at a time,
and every reply is the full radio state: `wifi`, `bluetooth`, `networks`,
`devices`, `wifiError` and `bluetoothError`. A failed operation is 409
`radio_failed` with the backend's message.

`GET /api/v1/storage` returns a `StorageStatus`: `policy` (`yes`, `no` or
`ask`), `location` (`device` or `sd`), `available`, `mediaHome`, `dataPath`,
`configPath`, `sdAvailable`, `needsPrompt`, `restartPending`,
`deviceProfileExists`, `sdProfileExists` and `error`. `POST` with a
`StorageSelection` of `policy` plus optional `adoptExisting` or
`replaceExisting` records the choice and answers 202 when a restart is
pending, 200 when only the selector changed. `{"retry":true}` retries a
pending move and `{"dismissOffer":true}` hides the card prompt. Conflicts
answer 409 `profile_conflict` or `storage_unavailable`.
`POST /api/v1/storage/card` takes `action`, `datastoreId`, `generation`,
`mountId` and `cardId` and answers 409 `card_busy` while another operation
runs. The flows behind these routes are in
[Storage and profiles](../app/storage.md) and
[Cadence supervision](cadence.md).
