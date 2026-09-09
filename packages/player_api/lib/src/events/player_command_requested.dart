import '../player_command.dart';
import 'player_event.dart';

/// Requests execution by the authoritative playback owner.
final class PlayerCommandRequested extends PlayerEvent {
  const PlayerCommandRequested({
    required super.sessionId,
    required this.requestId,
    required this.command,
  });

  final String requestId;
  final PlayerCommand command;

  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'type': 'commandRequested',
    'sessionId': sessionId,
    'requestId': requestId,
    'command': command.toJson(),
  };
}
