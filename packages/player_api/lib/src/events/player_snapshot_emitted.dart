import '../player_snapshot.dart';
import 'player_event.dart';

/// Publishes full owner state, including availability changes.
final class PlayerSnapshotEmitted extends PlayerEvent {
  const PlayerSnapshotEmitted({required super.sessionId, required this.state});

  final PlayerSnapshot state;

  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'type': 'snapshotEmitted',
    'sessionId': sessionId,
    'state': state.toJson(),
  };
}
