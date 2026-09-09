import '../player_snapshot.dart';
import 'player_event.dart';

/// Reports command completion with the owner's resulting snapshot.
final class PlayerCommandSucceeded extends PlayerEvent {
  const PlayerCommandSucceeded({
    required super.sessionId,
    required this.requestId,
    required this.state,
  });

  final String requestId;
  final PlayerSnapshot state;

  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'type': 'commandSucceeded',
    'sessionId': sessionId,
    'requestId': requestId,
    'state': state.toJson(),
  };
}
