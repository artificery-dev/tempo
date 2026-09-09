import 'dart:async';

import 'package:flutter/foundation.dart';

import 'library.dart';
import 'playback.dart';

/// One mutation sequence for local UI actions and daemon requests alike.
final class SerializedPlayback extends ChangeNotifier
    implements PlaybackService {
  SerializedPlayback(this.delegate) {
    delegate.addListener(notifyListeners);
  }
  final PlaybackService delegate;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  @override
  NowPlaying get value => delegate.value;

  Future<void> _run(Future<void> Function() action) {
    if (_disposed) return Future.error(StateError('Playback closed.'));
    final result = _tail.then((_) => action());
    _tail = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> play(List<TrackSummary> queue, {int index = 0}) {
    final tracks = List<TrackSummary>.unmodifiable(queue);
    return _run(() => delegate.play(tracks, index: index));
  }

  @override
  Future<void> toggle() => _run(delegate.toggle);
  @override
  Future<void> setPlaying(bool playing) =>
      _run(() => delegate.setPlaying(playing));
  @override
  Future<void> next() => _run(delegate.next);
  @override
  Future<void> previous() => _run(delegate.previous);
  @override
  Future<void> seekBy(Duration delta) => _run(() => delegate.seekBy(delta));
  @override
  Future<void> seekTo(Duration position) =>
      _run(() => delegate.seekTo(position));
  @override
  Future<void> stop() => _run(delegate.stop);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    delegate.removeListener(notifyListeners);
    unawaited(
      _tail.then((_) {
        if (delegate case ChangeNotifier notifier) notifier.dispose();
      }),
    );
    super.dispose();
  }
}
