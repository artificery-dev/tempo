import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/src/services/cadence_playback.dart';
import 'package:tempo_core/src/services/library.dart';
import 'package:tempo_core/src/services/playback.dart';

void main() {
  final tracks = [
    for (var i = 0; i < 3; i++)
      TrackSummary(id: i, fileId: i, path: '/Music/$i.flac', title: 'Track $i'),
  ];
  test(
    'resolves only the current item; queue keeps display identity',
    () async {
      final resolved = <int>[];
      final delegate = SilentPlayback();
      final playback = CadencePlayback(
        delegate,
        resolvePath: (track) async {
          resolved.add(track.id);
          return '/proc/42/fd/7/${track.id}.flac';
        },
      );
      await playback.play(tracks);
      expect(resolved, [0]);
      expect(delegate.value.track!.path, '/proc/42/fd/7/0.flac');
      expect(playback.value.track, same(tracks[0]));
      expect(playback.value.count, 3);
      await playback.next();
      expect(resolved, [0, 1]);
      expect(playback.value.index, 1);
      await playback.stop();
      expect(playback.value.hasTrack, false);
      playback.dispose();
    },
  );
  test(
    'stop during resolution prevents the decoder opening its result',
    () async {
      final result = Completer<String>();
      final delegate = SilentPlayback();
      final playback = CadencePlayback(
        delegate,
        resolvePath: (_) => result.future,
      );
      final pending = playback.play(tracks);
      await Future<void>.delayed(Duration.zero);
      final stopped = playback.stop();
      result.complete('/proc/old/track');
      await pending;
      await stopped;
      expect(delegate.value.hasTrack, false);
      playback.dispose();
    },
  );
  test(
    'natural completion advances through IDs instead of cached paths',
    () async {
      final delegate = SilentPlayback();
      final resolved = <int>[];
      final playback = CadencePlayback(
        delegate,
        resolvePath: (track) async {
          resolved.add(track.id);
          return '/resolved/${track.id}';
        },
      );
      await playback.play(tracks);
      await delegate.stop();
      await Future<void>.delayed(Duration.zero);
      expect(playback.value.index, 1);
      expect(resolved, [0, 1]);
      await playback.stop();
      playback.dispose();
    },
  );
}
