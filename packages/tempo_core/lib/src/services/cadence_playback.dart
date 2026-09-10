import 'dart:async';
import 'package:flutter/foundation.dart';
import 'library.dart';
import 'playback.dart';

/// Resolve each item immediately before opening it. Only the current decoder
/// holds a Cadence path; queued tracks keep their library identities.
class CadencePlayback extends ChangeNotifier implements PlaybackService {
  CadencePlayback(this.delegate, {required this.resolvePath}) {
    delegate.addListener(_changed);
  }
  final PlaybackService delegate;
  final Future<String> Function(TrackSummary) resolvePath;
  List<TrackSummary> _queue = const [];
  int _index = 0, _generation = 0;
  bool _closed = false, _loading = false, _hadTrack = false;
  Future<void> _tail = Future.value();
  String? error;
  @override
  NowPlaying get value {
    if (_queue.isEmpty) return NowPlaying.nothing;
    final reading = delegate.value;
    return NowPlaying(
      track: _queue[_index],
      state: reading.state,
      position: reading.position,
      duration: reading.duration,
      index: _index,
      count: _queue.length,
    );
  }

  Future<void> _run(Future<void> Function() action) {
    if (_closed) return Future.error(StateError('Playback closed'));
    final result = _tail.then((_) => action());
    _tail = result.catchError((Object failure) {
      error = '$failure';
      if (!_closed) notifyListeners();
    });
    return result;
  }

  void _changed() {
    if (_closed) return;
    final hadTrack = _hadTrack;
    _hadTrack = delegate.value.hasTrack;
    if (!_loading && hadTrack && !_hadTrack && _queue.isNotEmpty) {
      unawaited(next().catchError((Object _) {}));
    }
    notifyListeners();
  }

  Future<void> _load(int index, int generation) async {
    if (_closed || generation != _generation) return;
    if (index >= _queue.length) {
      await _stop();
      return;
    }
    _index = index;
    _loading = true;
    try {
      await delegate.stop();
      final track = _queue[index];
      final path = await resolvePath(track);
      if (_closed || generation != _generation) return;
      final resolved = TrackSummary(
        id: track.id,
        fileId: track.fileId,
        path: path,
        title: track.title,
        artist: track.artist,
        album: track.album,
        albumArtist: track.albumArtist,
        trackNumber: track.trackNumber,
        discNumber: track.discNumber,
        duration: track.duration,
        year: track.year,
        genre: track.genre,
      );
      await delegate.play([resolved]);
      _hadTrack = delegate.value.hasTrack;
      error = null;
    } catch (_) {
      _queue = const [];
      rethrow;
    } finally {
      _loading = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  Future<void> play(List<TrackSummary> queue, {int index = 0}) {
    final generation = ++_generation;
    final tracks = List<TrackSummary>.unmodifiable(queue);
    return _run(() async {
      if (generation != _generation) return;
      _queue = tracks;
      if (tracks.isEmpty) {
        await _stop();
        return;
      }
      await _load(index.clamp(0, tracks.length - 1), generation);
    });
  }

  @override
  Future<void> next() => _run(() => _load(_index + 1, _generation));
  @override
  Future<void> previous() => _run(() async {
    if (_queue.isEmpty) return;
    if (delegate.value.position > previousWindow) {
      await delegate.seekTo(Duration.zero);
    } else {
      await _load((_index - 1).clamp(0, _queue.length - 1), _generation);
    }
  });
  @override
  Future<void> toggle() => _run(delegate.toggle);
  @override
  Future<void> setPlaying(bool playing) =>
      _run(() => delegate.setPlaying(playing));
  @override
  Future<void> seekTo(Duration position) =>
      _run(() => delegate.seekTo(position));
  @override
  Future<void> seekBy(Duration delta) => _run(() => delegate.seekBy(delta));
  Future<void> _stop() async {
    _queue = const [];
    _hadTrack = false;
    await delegate.stop();
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> stop() {
    ++_generation; // Cancel in-flight resolution before waiting for its result.
    return _run(_stop);
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    ++_generation;
    delegate.removeListener(_changed);
    unawaited(
      _tail.then((_) async {
        await delegate.stop();
        if (delegate case ChangeNotifier notifier) notifier.dispose();
      }),
    );
    super.dispose();
  }
}
