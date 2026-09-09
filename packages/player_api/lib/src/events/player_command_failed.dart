import '../player_failure.dart';
import 'player_event.dart';

/// Reports a command failure safe to expose to the requesting peer.
final class PlayerCommandFailed extends PlayerEvent {
  const PlayerCommandFailed({
    required super.sessionId,
    required this.requestId,
    required this.failure,
  });

  final String requestId;
  final PlayerFailure failure;

  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'type': 'commandFailed',
    'sessionId': sessionId,
    'requestId': requestId,
    'error': {'code': failure.code, 'message': failure.message},
  };
}
