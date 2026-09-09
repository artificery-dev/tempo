import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../status.dart';
import 'library.dart';

/// What is playing: the track, the state, where in it we are, and where
/// in the queue. [nothing] is the player with nothing loaded.
@immutable
class NowPlaying {
  const NowPlaying({
    this.track,
    this.state = PlaybackState.stopped,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.index = 0,
    this.count = 0,
  });

  static const nothing = NowPlaying();

  final TrackSummary? track;
  final PlaybackState state;
  final Duration position;

  /// The track's length as the player found it - or, before it has, as
  /// the library tagged it.
  final Duration duration;

  /// Where in the queue the track is, and how long the queue is.
  final int index;
  final int count;

  bool get hasTrack => track != null;
  bool get playing => state == PlaybackState.playing;
  bool get hasNext => index + 1 < count;
  bool get hasPrevious => index > 0;

  /// How far through the track, 0 to 1.
  double get progress => duration == Duration.zero
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  NowPlaying copyWith({
    TrackSummary? track,
    PlaybackState? state,
    Duration? position,
    Duration? duration,
    int? index,
    int? count,
  }) => NowPlaying(
    track: track ?? this.track,
    state: state ?? this.state,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    index: index ?? this.index,
    count: count ?? this.count,
  );

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      other.track == track &&
      other.state == state &&
      other.position == position &&
      other.duration == duration &&
      other.index == index &&
      other.count == count;

  @override
  int get hashCode =>
      Object.hash(track, state, position, duration, index, count);
}

/// The player: a queue of tracks and the one of them being heard.
///
/// The UI reads [value] and speaks the click wheel's words - play, next,
/// previous, and the seeks the held buttons mean. [Playback.state] in the
/// bars follows this; nothing writes it by hand any more.
abstract class PlaybackService implements ValueListenable<NowPlaying> {
  /// Play [queue] from [index], replacing whatever was queued.
  Future<void> play(List<TrackSummary> queue, {int index = 0});

  /// Play if paused, pause if playing; nothing when nothing is loaded.
  Future<void> toggle();

  Future<void> setPlaying(bool playing);

  Future<void> seekTo(Duration position);

  /// The next track in the queue. At the end, stop - the way a click
  /// wheel has always ended a list.
  Future<void> next();

  /// Back to the start of this track, or - within its first seconds -
  /// to the track before.
  Future<void> previous();

  /// Move [delta] within the track, held at its ends.
  Future<void> seekBy(Duration delta);

  /// Stop, and let the queue go.
  Future<void> stop();
}

/// How far back into a track "previous" still means the one before.
const previousWindow = Duration(seconds: 3);

typedef _SetLocaleC = Pointer<Utf8> Function(Int32, Pointer<Utf8>);
typedef _SetLocaleDart = Pointer<Utf8> Function(int, Pointer<Utf8>);

/// The state the bars show, kept in step with whatever player is speaking.
mixin _PublishesState on ValueNotifier<NowPlaying> {
  void publish(NowPlaying next) {
    if (next == value) return;
    value = next;
    if (Playback.state.value != next.state) Playback.state.value = next.state;
  }
}

/// A player that makes no sound: the queue, the state, the position moved
/// by hand. What the emulator's rig plays when the host has no libmpv,
/// and what a test plays.
class SilentPlayback extends ValueNotifier<NowPlaying>
    with _PublishesState
    implements PlaybackService {
  SilentPlayback() : super(NowPlaying.nothing);

  static final shared = SilentPlayback();

  List<TrackSummary> _queue = const [];

  @override
  Future<void> play(List<TrackSummary> queue, {int index = 0}) async {
    if (queue.isEmpty) return stop();
    _queue = queue;
    _load(index.clamp(0, queue.length - 1));
  }

  void _load(int index) {
    final track = _queue[index];
    publish(
      NowPlaying(
        track: track,
        state: PlaybackState.playing,
        duration: track.duration ?? Duration.zero,
        index: index,
        count: _queue.length,
      ),
    );
  }

  @override
  Future<void> setPlaying(bool playing) async {
    if (!value.hasTrack) return;
    publish(
      value.copyWith(
        state: playing ? PlaybackState.playing : PlaybackState.paused,
      ),
    );
  }

  @override
  Future<void> seekTo(Duration position) => seekBy(position - value.position);

  @override
  Future<void> toggle() async {
    if (!value.hasTrack) return;
    publish(
      value.copyWith(
        state: value.playing ? PlaybackState.paused : PlaybackState.playing,
      ),
    );
  }

  @override
  Future<void> next() async {
    if (!value.hasTrack) return;
    if (value.hasNext) {
      _load(value.index + 1);
    } else {
      await stop();
    }
  }

  @override
  Future<void> previous() async {
    if (!value.hasTrack) return;
    if (value.position > previousWindow || !value.hasPrevious) {
      publish(value.copyWith(position: Duration.zero));
    } else {
      _load(value.index - 1);
    }
  }

  @override
  Future<void> seekBy(Duration delta) async {
    if (!value.hasTrack) return;
    var at = value.position + delta;
    if (at < Duration.zero) at = Duration.zero;
    if (at > value.duration) at = value.duration;
    publish(value.copyWith(position: at));
  }

  @override
  Future<void> stop() async {
    _queue = const [];
    publish(NowPlaying.nothing);
  }
}

/// The player over libmpv, through media_kit: audio only, no video
/// surface, no platform plugin - dart:ffi to the system's libmpv, which
/// is what lets it run whole under flutter-pi. mpv picks the output
/// itself; on the device that is PipeWire, in the user's own session.
class MediaKitPlayback extends ValueNotifier<NowPlaying>
    with _PublishesState
    implements PlaybackService {
  /// Loads libmpv - by the usual sonames, or [libmpv] when told where -
  /// and makes the player. Throws when there is no libmpv to load; the
  /// caller falls back to a [SilentPlayback] and says so.
  MediaKitPlayback({String? libmpv}) : super(NowPlaying.nothing) {
    MediaKit.ensureInitialized(libmpv: libmpv);
    _numericLocaleC();
    _player = Player(
      configuration: const PlayerConfiguration(title: 'Tempo', osc: false),
    );
    // Sound only: no video decode, no cover art as a picture, and none
    // of mpv's hunting for subtitles and audio files named like the
    // track - the .lrc beside every song is the library's, not mpv's.
    final native = _player.platform;
    if (native is NativePlayer) {
      for (final MapEntry(:key, :value) in const {
        'vid': 'no',
        'audio-display': 'no',
        'sub-auto': 'no',
        'audio-file-auto': 'no',
      }.entries) {
        unawaited(native.setProperty(key, value));
      }
    }
    _subscriptions = [
      _player.stream.playing.listen(_playingMoved),
      _player.stream.position.listen(_positionMoved),
      _player.stream.duration.listen(_durationMoved),
      _player.stream.playlist.listen(_playlistMoved),
      _player.stream.completed.listen(_completedMoved),
      _player.stream.error.listen(
        (message) => debugPrint('playback: $message'),
      ),
    ];
  }

  late final Player _player;
  late final List<StreamSubscription<Object?>> _subscriptions;
  List<TrackSummary> _queue = const [];

  /// libmpv refuses to be created under any numeric locale but "C" (it
  /// parses its own option strings with strtod), and the device runs the
  /// frontend under en_US.UTF-8 - so the numeric category alone is put
  /// back to C here, in this process, before the player is made. Nothing
  /// of ours formats numbers through libc; Dart does its own.
  static void _numericLocaleC() {
    if (!Platform.isLinux) return;
    try {
      final setlocale = DynamicLibrary.process()
          .lookupFunction<_SetLocaleC, _SetLocaleDart>('setlocale');
      final c = 'C'.toNativeUtf8();
      try {
        setlocale(_lcNumeric, c);
      } finally {
        malloc.free(c);
      }
    } on Object catch (error) {
      debugPrint('playback: could not set LC_NUMERIC=C: $error');
    }
  }

  /// glibc's LC_NUMERIC.
  static const _lcNumeric = 1;

  /// True between a stop and the next play: mpv reports "not playing"
  /// both for a pause and for an empty player, and only we know which.
  bool _stopped = true;

  void _playingMoved(bool playing) {
    if (_stopped) return;
    publish(
      value.copyWith(
        state: playing ? PlaybackState.playing : PlaybackState.paused,
      ),
    );
  }

  void _positionMoved(Duration position) {
    if (_stopped) return;
    // To the second: the strip on home draws no finer, and every finer
    // tick would be a frame.
    final seconds = Duration(seconds: position.inSeconds);
    if (seconds == value.position) return;
    publish(value.copyWith(position: seconds));
  }

  void _durationMoved(Duration duration) {
    if (_stopped || duration == Duration.zero) return;
    publish(value.copyWith(duration: duration));
  }

  void _playlistMoved(Playlist playlist) {
    if (_stopped || _queue.isEmpty) return;
    final index = playlist.index.clamp(0, _queue.length - 1);
    if (index == value.index && value.track == _queue[index]) return;
    final track = _queue[index];
    publish(
      value.copyWith(
        track: track,
        index: index,
        position: Duration.zero,
        duration: track.duration ?? Duration.zero,
      ),
    );
  }

  void _completedMoved(bool completed) {
    if (!completed || _stopped) return;
    // mpv moves on to the next entry by itself; the end of the last one is
    // the end of the queue.
    if (!value.hasNext) unawaited(stop());
  }

  @override
  Future<void> play(List<TrackSummary> queue, {int index = 0}) async {
    if (queue.isEmpty) return stop();
    _queue = queue;
    _stopped = false;
    final at = index.clamp(0, queue.length - 1);
    final track = queue[at];
    publish(
      NowPlaying(
        track: track,
        state: PlaybackState.playing,
        duration: track.duration ?? Duration.zero,
        index: at,
        count: queue.length,
      ),
    );
    await _player.open(
      Playlist([for (final track in queue) Media(track.path)], index: at),
    );
  }

  @override
  Future<void> setPlaying(bool playing) async {
    if (_stopped) return;
    if (playing) {
      await _player.play();
    } else {
      await _player.pause();
    }
    _playingMoved(_player.state.playing);
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_stopped) return;
    final duration = _player.state.duration;
    if (position < Duration.zero) position = Duration.zero;
    if (duration > Duration.zero && position > duration) position = duration;
    await _player.seek(position);
    _positionMoved(position);
  }

  @override
  Future<void> toggle() async {
    if (_stopped) return;
    await setPlaying(!_player.state.playing);
  }

  @override
  Future<void> next() async {
    if (_stopped) return;
    if (value.hasNext) {
      await _player.next();
    } else {
      await stop();
    }
  }

  @override
  Future<void> previous() async {
    if (_stopped) return;
    if (value.position > previousWindow || !value.hasPrevious) {
      await _player.seek(Duration.zero);
    } else {
      await _player.previous();
    }
  }

  @override
  Future<void> seekBy(Duration delta) async {
    if (_stopped) return;
    var at = _player.state.position + delta;
    if (at < Duration.zero) at = Duration.zero;
    final duration = _player.state.duration;
    if (duration != Duration.zero && at > duration) at = duration;
    await _player.seek(at);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _queue = const [];
    publish(NowPlaying.nothing);
    await _player.stop();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }
}
