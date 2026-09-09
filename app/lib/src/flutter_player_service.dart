import 'dart:async';

import 'package:player_api/player_api.dart';
import 'package:tempo_core/tempo_core.dart';

/// Exposes the existing Flutter player; no second playback engine or queue.
final class FlutterPlayerService implements PlayerService {
  FlutterPlayerService({
    required this.playback,
    required this.volume,
    this.fmRadio,
  }) {
    _state = _read(0);
    playback.addListener(_changed);
    volume.addListener(_changed);
    fmRadio?.addListener(_changed);
    VideoPlayback.session.addListener(_changed);
  }
  final PlaybackService playback;
  final VolumeService volume;
  final FmRadioService? fmRadio;
  final _changes = StreamController<PlayerSnapshot>.broadcast(sync: true);
  late PlayerSnapshot _state;
  bool _closed = false;
  bool _busy = false;
  Completer<void>? _idle;

  PlayerSnapshot _read(int revision) {
    if (VideoPlayback.active != null || (fmRadio?.value.on ?? false)) {
      return PlayerSnapshot(
        revision: revision,
        available: false,
        volume: volume.value.level.clamp(0, 100) / 100,
      );
    }
    final now = playback.value;
    return PlayerSnapshot(
      revision: revision,
      available: !_closed,
      status: switch (now.state) {
        PlaybackState.playing => PlaybackStatus.playing,
        PlaybackState.paused => PlaybackStatus.paused,
        PlaybackState.stopped => PlaybackStatus.stopped,
      },
      trackId: now.track?.id.toString(),
      title: now.track?.title,
      artist: now.track?.artist,
      album: now.track?.album,
      hasNext: now.hasNext,
      positionMs: now.position.inMilliseconds.clamp(0, 0x7fffffffffffffff),
      durationMs: now.duration.inMilliseconds.clamp(0, 0x7fffffffffffffff),
      volume: volume.value.level.clamp(0, 100) / 100,
    );
  }

  void _changed() {
    if (_closed) return;
    _state = _read(_state.revision + 1);
    _changes.add(_state);
  }

  @override
  PlayerSnapshot get snapshot => _state;
  @override
  Stream<PlayerSnapshot> get changes => _changes.stream;

  @override
  Future<PlayerSnapshot> execute(PlayerCommand command) async {
    if (_closed) {
      throw const PlayerFailure('player_unavailable', 'Player closed.');
    }
    if (_busy) {
      throw const PlayerFailure('player_busy', 'A command is running.');
    }
    if (!_state.available) {
      throw const PlayerFailure(
        'player_unavailable',
        'Music controls are unavailable during video or FM playback.',
      );
    }
    _busy = true;
    final idle = _idle = Completer<void>();
    try {
      if (!playback.value.hasTrack &&
          command.action != PlayerAction.setVolume &&
          command.action != PlayerAction.stop) {
        throw const PlayerFailure('no_track', 'No track is loaded.');
      }
      switch (command.action) {
        case PlayerAction.play:
          await playback.setPlaying(true);
        case PlayerAction.pause:
          await playback.setPlaying(false);
        case PlayerAction.stop:
          await playback.stop();
        case PlayerAction.toggle:
          await playback.toggle();
        case PlayerAction.next:
          await playback.next();
        case PlayerAction.previous:
          await playback.previous();
        case PlayerAction.seek:
          await playback.seekTo(
            Duration(
              milliseconds: command.value!.toInt().clamp(
                0,
                playback.value.duration.inMilliseconds,
              ),
            ),
          );
        case PlayerAction.setVolume:
          final level = (command.value! * 100).round();
          final mixer = volume;
          if (mixer is DeviceVolume) {
            await mixer.setLevelConfirmed(level);
          } else {
            await mixer.setLevel(level);
          }
      }
      _changed();
      return _state;
    } on PlayerFailure {
      rethrow;
    } catch (_) {
      throw const PlayerFailure('command_failed', 'Playback operation failed.');
    } finally {
      _busy = false;
      idle.complete();
      _idle = null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _idle?.future;
    playback.removeListener(_changed);
    volume.removeListener(_changed);
    fmRadio?.removeListener(_changed);
    VideoPlayback.session.removeListener(_changed);
    _state = _read(_state.revision + 1);
    _changes.add(_state);
    await _changes.close();
  }
}
