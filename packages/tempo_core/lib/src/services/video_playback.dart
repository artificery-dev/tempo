import 'dart:io';

import 'package:tomeui/tomeui.dart';
import 'package:video_player/video_player.dart';

import '../status.dart';
import 'library.dart';
import 'playback.dart';
import 'volume.dart';

/// A video session owns transport and survives navigation away from Home.
class VideoPlayback extends ValueNotifier<NowPlaying>
    implements PlaybackService {
  VideoPlayback() : super(NowPlaying.nothing);
  static final session = ValueNotifier<VideoPlayback?>(null);
  static final keepAwake = ValueNotifier(false);
  static VideoPlayback? get active => session.value;
  static set active(VideoPlayback? value) {
    session.value = value;
    Playback.state.value = value?.value.state ?? PlaybackState.stopped;
    keepAwake.value = value?.controller?.value.isPlaying ?? false;
  }

  VideoPlayerController? controller;
  String? error;
  bool _disposed = false;
  int _generation = 0;
  double _volume = 1;

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    if (controller?.value.isInitialized ?? false) {
      await controller!.setVolume(_volume);
    }
  }

  VolumeService? _softwareVolume;

  /// Session lifetime, rather than a screen's lifetime, owns these listeners.
  void attach({required VolumeService volume}) {
    if (volume is VolumeSwitch) {
      _softwareVolume = volume;
      volume.addListener(_volumeChanged);
      _volumeChanged();
    }
  }

  void _volumeChanged() {
    final reading = _softwareVolume!.value;
    setVolume(reading.muted ? 0 : reading.level / 100);
  }

  @override
  Future<void> play(List<TrackSummary> queue, {int index = 0}) async {
    if (queue.isEmpty) return stop();
    final generation = ++_generation;
    final previous = controller;
    controller = null;
    await previous?.dispose();
    if (_disposed || generation != _generation) return;
    error = null;
    final track = queue[index.clamp(0, queue.length - 1)];
    final next = VideoPlayerController.file(File(track.path));
    controller = next;
    value = NowPlaying(track: track, count: 1);
    next.addListener(_changed);
    try {
      await next.initialize();
      if (_disposed || generation != _generation) return;
      await next.setVolume(_volume);
      if (_disposed || generation != _generation) return;
      if (identical(active, this)) {
        await next.play();
      }
    } on Object catch (failure) {
      if (_disposed || generation != _generation) return;
      error = 'Could not play this video: $failure';
      notifyListeners();
    }
  }

  void _changed() {
    final video = controller?.value;
    if (_disposed || video == null) return;
    error = video.errorDescription;
    final state = video.isPlaying
        ? PlaybackState.playing
        : PlaybackState.paused;
    value = value.copyWith(
      state: state,
      position: video.position,
      duration: video.duration,
    );
    if (identical(active, this)) {
      Playback.state.value = state;
      keepAwake.value = video.isPlaying;
    }
  }

  @override
  Future<void> setPlaying(bool playing) async {
    final video = controller;
    if (video == null || !video.value.isInitialized) return;
    if (playing) {
      await video.play();
    } else {
      await video.pause();
    }
    _changed();
  }

  @override
  Future<void> seekTo(Duration position) => seekBy(position - value.position);

  @override
  Future<void> toggle() async {
    final video = controller;
    if (video == null || !video.value.isInitialized) return;
    if (video.value.isPlaying) {
      await video.pause();
    } else {
      await video.play();
    }
  }

  @override
  Future<void> previous() => seekBy(-value.position);
  @override
  Future<void> next() => stop();
  @override
  Future<void> seekBy(Duration delta) async {
    final video = controller;
    if (video == null || !video.value.isInitialized) return;
    final ms = (video.value.position + delta).inMilliseconds.clamp(
      0,
      video.value.duration.inMilliseconds,
    );
    await video.seekTo(Duration(milliseconds: ms));
  }

  @override
  Future<void> stop() async {
    await controller?.pause();
    await controller?.seekTo(Duration.zero);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _softwareVolume?.removeListener(_volumeChanged);
    controller?.removeListener(_changed);
    controller?.dispose();
    if (identical(active, this)) {
      active = null;
      Playback.state.value = PlaybackState.stopped;
    }
    super.dispose();
  }
}
