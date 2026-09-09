import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';

void main() {
  test(
    'local and API actions share ordering, even after an operation fails',
    () async {
      final delegate = _DelayedPlayback();
      final player = SerializedPlayback(delegate);
      final first = player.setPlaying(false);
      final failure = expectLater(first, throwsStateError);
      await delegate.entered.future;
      final next = player.next();
      expect(delegate.skipped, isFalse);
      delegate.release.complete();
      await failure;
      await next;
      expect(delegate.skipped, isTrue);
      player.dispose();
    },
  );
}

final class _DelayedPlayback extends SilentPlayback {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool skipped = false;
  @override
  Future<void> setPlaying(bool playing) async {
    entered.complete();
    await release.future;
    throw StateError('Playback failed');
  }

  @override
  Future<void> next() async {
    skipped = true;
  }
}
