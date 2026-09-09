import 'dart:async';

import 'player_command.dart';
import 'player_snapshot.dart';

/// Implemented by the authoritative playback owner, not by each transport.
///
/// Mutations must be serialized by the implementation. Publish [snapshot]
/// before emitting it on [changes], with a strictly increasing revision.
/// Snapshot reads and subscription setup run on the same isolate without an
/// asynchronous gap. Streams are broadcast; cancelling one subscription must
/// not stop the service. Only full snapshots are emitted, allowing transports
/// to coalesce updates for slow consumers without losing the final state.
abstract interface class PlayerService {
  PlayerSnapshot get snapshot;
  Stream<PlayerSnapshot> get changes;
  Future<PlayerSnapshot> execute(PlayerCommand command);
}
