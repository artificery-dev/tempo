import 'player_event.dart';

/// Requests a fresh snapshot from the known playback-owner session.
final class PlayerSyncRequested extends PlayerEvent {
  const PlayerSyncRequested({required super.sessionId});

  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'type': 'syncRequested',
    'sessionId': sessionId,
  };
}
