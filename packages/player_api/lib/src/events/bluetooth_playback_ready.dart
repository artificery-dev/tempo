import 'player_event.dart';

/// Private owner notification after BlueZ has advertised playback state.
/// [stateRevision] identifies the latest owner snapshot known to the daemon;
/// the owner must reject readiness older than its latest playback transition.
final class BluetoothPlaybackReady extends PlayerEvent {
  const BluetoothPlaybackReady({
    required super.sessionId,
    required this.stateRevision,
    required this.active,
  });
  final int stateRevision;
  final bool active;
  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'type': 'bluetoothPlaybackReady',
    'sessionId': sessionId,
    'stateRevision': stateRevision,
    'active': active,
  };
}
