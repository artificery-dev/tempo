import 'dart:async';

import 'package:player_api/player_api.dart';

/// Explicit development backend. It changes state but never plays audio.
final class DemoPlayer implements PlayerService {
  final _changes = StreamController<PlayerSnapshot>.broadcast(sync: true);
  var _state = const PlayerSnapshot(
    revision: 0,
    available: true,
    status: PlaybackStatus.paused,
    trackId: 'demo:1',
    title: 'Demo track',
    durationMs: 180000,
  );
  bool _closed = false;

  @override
  PlayerSnapshot get snapshot => _state;
  @override
  Stream<PlayerSnapshot> get changes => _changes.stream;
  @override
  Future<PlayerSnapshot> execute(PlayerCommand command) async {
    if (_closed) {
      throw const PlayerFailure('player_unavailable', 'Player closed.');
    }
    var status = _state.status;
    var position = _state.positionMs;
    var volume = _state.volume;
    switch (command.action) {
      case PlayerAction.play:
        status = PlaybackStatus.playing;
      case PlayerAction.pause:
        status = PlaybackStatus.paused;
      case PlayerAction.stop:
        status = PlaybackStatus.stopped;
        position = 0;
      case PlayerAction.toggle:
        status = status == PlaybackStatus.playing
            ? PlaybackStatus.paused
            : PlaybackStatus.playing;
      case PlayerAction.seek:
        position = command.value!.toInt().clamp(0, _state.durationMs);
      case PlayerAction.setVolume:
        volume = command.value!.toDouble();
      case PlayerAction.next || PlayerAction.previous:
        throw const PlayerFailure('unsupported_command', 'Demo has one track.');
    }
    _state = PlayerSnapshot(
      revision: _state.revision + 1,
      available: true,
      status: status,
      trackId: _state.trackId,
      title: _state.title,
      positionMs: position,
      durationMs: _state.durationMs,
      volume: volume,
    );
    _changes.add(_state);
    return _state;
  }

  Future<void> close() async {
    _closed = true;
    await _changes.close();
  }
}
