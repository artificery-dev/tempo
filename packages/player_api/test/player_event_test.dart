import 'package:player_api/player_api.dart';
import 'package:test/test.dart';

void main() {
  const state = PlayerSnapshot(revision: 4, available: true);
  final events = <PlayerEvent>[
    PlayerCommandRequested(
      sessionId: 'owner-1',
      requestId: 'request-2',
      command: PlayerCommand.fromJson({'type': 'play'}),
    ),
    const PlayerCommandSucceeded(
      sessionId: 'owner-1',
      requestId: 'request-2',
      state: state,
    ),
    const PlayerCommandFailed(
      sessionId: 'owner-1',
      requestId: 'request-2',
      failure: PlayerFailure('player_unavailable', 'No player is connected.'),
    ),
    const PlayerSnapshotEmitted(sessionId: 'owner-1', state: state),
    const PlayerSyncRequested(sessionId: 'owner-1'),
    const BluetoothPlaybackReady(
      sessionId: 'owner-1',
      stateRevision: 4,
      active: true,
    ),
  ];

  test(
    'every event preserves its type, session, and payload on round trip',
    () {
      for (final event in events) {
        final decoded = PlayerEvent.fromJson(event.toJson());
        expect(decoded.runtimeType, event.runtimeType);
        expect(decoded.toJson(), event.toJson());
        expect(
          PlayerEvent.fromJson({...event.toJson(), 'future': true}).toJson(),
          event.toJson(),
        );
      }
    },
  );

  test('rejects unsupported envelopes and malformed nested payloads', () {
    for (final input in <Object?>[
      {...events.last.toJson(), 'stateRevision': -1},
      {...events.last.toJson(), 'active': 'yes'},
      null,
      [],
      'snapshotEmitted',
      {},
      {...events.first.toJson(), 'version': 2},
      {...events.first.toJson(), 'version': 1.0},
      {...events.first.toJson(), 'type': 'unknown'},
      {...events.first.toJson(), 'sessionId': ''},
      {...events.first.toJson(), 'sessionId': 1},
      {...events.first.toJson(), 'requestId': ' '},
      {
        ...events.first.toJson(),
        'command': {'type': 'seek', 'positionMs': -1},
      },
      {...events[1].toJson(), 'requestId': null},
      {
        ...events[1].toJson(),
        'state': {'revision': 1},
      },
      {
        ...events[2].toJson(),
        'error': {'code': '', 'message': 'Failure'},
      },
      {
        ...events[2].toJson(),
        'error': {'code': 'failed', 'message': 1},
      },
      {
        ...events[3].toJson(),
        'state': {...state.toJson(), 'available': 'yes'},
      },
    ]) {
      expect(
        () => PlayerEvent.fromJson(input),
        throwsFormatException,
        reason: '$input',
      );
    }
  });

  test(
    'availability and session resets are carried without merging revisions',
    () {
      final disconnected =
          PlayerEvent.fromJson(
                const PlayerSnapshotEmitted(
                  sessionId: 'owner-1',
                  state: PlayerSnapshot(revision: 5, available: false),
                ).toJson(),
              )
              as PlayerSnapshotEmitted;
      final restarted =
          PlayerEvent.fromJson(
                const PlayerSnapshotEmitted(
                  sessionId: 'owner-2',
                  state: PlayerSnapshot(revision: 0, available: true),
                ).toJson(),
              )
              as PlayerSnapshotEmitted;
      expect(disconnected.state.available, isFalse);
      expect(restarted.sessionId, isNot(disconnected.sessionId));
      expect(restarted.state.revision, 0);
    },
  );
}
