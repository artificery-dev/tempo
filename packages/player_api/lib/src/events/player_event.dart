import 'bluetooth_playback_ready.dart';
import '../player_command.dart';
import '../player_failure.dart';
import '../player_snapshot.dart';
import 'player_command_failed.dart';
import 'player_command_requested.dart';
import 'player_command_succeeded.dart';
import 'player_snapshot_emitted.dart';
import 'player_sync_requested.dart';

/// A transport-independent message exchanged with one playback-owner session.
/// Transports authenticate peers and enforce delivery/size limits separately.
abstract class PlayerEvent {
  const PlayerEvent({required this.sessionId});

  /// Identifies the playback owner session, not an individual connection.
  final String sessionId;

  Map<String, Object?> toJson();

  /// Decode protocol version 1. Unknown event types and versions are rejected;
  /// additional envelope fields are ignored for additive compatibility.
  factory PlayerEvent.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        input['version'] != 1 ||
        input['version'] is! int) {
      throw const FormatException('Expected player event version 1.');
    }
    String identifier(String key) {
      final value = input[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key must be a nonempty string.');
      }
      return value;
    }

    final sessionId = identifier('sessionId');
    switch (input['type']) {
      case 'commandRequested':
        return PlayerCommandRequested(
          sessionId: sessionId,
          requestId: identifier('requestId'),
          command: PlayerCommand.fromJson(input['command']),
        );
      case 'commandSucceeded':
        return PlayerCommandSucceeded(
          sessionId: sessionId,
          requestId: identifier('requestId'),
          state: PlayerSnapshot.fromJson(input['state']),
        );
      case 'commandFailed':
        final error = input['error'];
        if (error is! Map<String, dynamic> ||
            error['code'] is! String ||
            (error['code'] as String).trim().isEmpty ||
            error['message'] is! String) {
          throw const FormatException('Invalid command failure.');
        }
        return PlayerCommandFailed(
          sessionId: sessionId,
          requestId: identifier('requestId'),
          failure: PlayerFailure(
            error['code'] as String,
            error['message'] as String,
          ),
        );
      case 'snapshotEmitted':
        return PlayerSnapshotEmitted(
          sessionId: sessionId,
          state: PlayerSnapshot.fromJson(input['state']),
        );
      case 'bluetoothPlaybackReady':
        final revision = input['stateRevision'];
        final active = input['active'];
        if (revision is! int || revision < 0 || active is! bool) {
          throw const FormatException('Invalid Bluetooth readiness.');
        }
        return BluetoothPlaybackReady(
          sessionId: sessionId,
          stateRevision: revision,
          active: active,
        );
      case 'syncRequested':
        return PlayerSyncRequested(sessionId: sessionId);
      default:
        throw const FormatException('Unknown player event type.');
    }
  }
}
