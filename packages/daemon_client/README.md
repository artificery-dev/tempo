# Daemon client

Pure-Dart transports used by the device app, without Flutter or Relic imports.
Domain player events remain in `player_api`.

- `Tempod`: existing native Unix control protocol and `TempodError`.
- `PlaybackOwnerConnection`: authenticated WebSocket attachment of an existing
  `PlayerService`, bounded snapshot replies, command results, and reconnect.
- `DeviceClient`: authenticated cached device observations; errors become
  unknown state, with no local hardware fallback.
- `DeviceSnapshot`: battery and card-mount observations.

Clients own their connections and timers; call `close()` when their owner exits.
No command is automatically retried after disconnect. See `daemon/README.md`
for credentials, configuration, limits, and current migration boundaries.
