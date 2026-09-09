import 'package:test/test.dart';
import 'package:player_api/player_api.dart';
import 'package:daemon_client/src/playback_readiness_gate.dart';

void main() {
  test('stale ready cannot flush after pause/resume or disconnect', () {
    PlayerSnapshot state(int revision, PlaybackStatus status) =>
        PlayerSnapshot(revision: revision, available: true, status: status);
    final results = <bool>[];
    final gate = PlaybackReadinessGate(
      state(1, PlaybackStatus.playing),
      results.add,
    )..connected();
    void ready(int revision) => gate.receive(
      BluetoothPlaybackReady(
        sessionId: 'session',
        stateRevision: revision,
        active: true,
      ),
    );
    ready(1);
    expect(results.last, true);
    gate.update(state(2, PlaybackStatus.paused));
    ready(1);
    expect(results.last, false);
    gate.update(state(3, PlaybackStatus.playing));
    ready(1);
    expect(results.last, false);
    gate.update(state(4, PlaybackStatus.playing));
    ready(3);
    expect(results.last, true);
    gate.disconnected();
    ready(4);
    expect(results.last, false);
    gate.connected();
    ready(3);
    expect(results.last, false);
    ready(4);
    expect(results.last, true);
    ready(10);
    expect(results.where((v) => v).length, 3);
  });
}
