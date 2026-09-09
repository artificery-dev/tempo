import 'package:flutter_test/flutter_test.dart';
import 'package:player_api/player_api.dart';
import 'package:tempo/src/flutter_player_service.dart';
import 'package:tempo_core/tempo_core.dart';

const track = TrackSummary(
  id: 1,
  fileId: 1,
  path: '/music/test.ogg',
  title: 'Test',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
);

void main() {
  test('API drives the existing queue and observes local UI changes', () async {
    final playback = SerializedPlayback(SilentPlayback());
    final volume = VolumeSwitch();
    final player = FlutterPlayerService(playback: playback, volume: volume);
    final states = <PlayerSnapshot>[];
    final subscription = player.changes.listen(states.add);
    try {
      await expectLater(
        player.execute(PlayerCommand.fromJson({'type': 'play'})),
        throwsA(isA<PlayerFailure>().having((e) => e.code, 'code', 'no_track')),
      );
      await playback.play(const [track]);
      expect(player.snapshot.trackId, '1');
      expect(player.snapshot.artist, 'Artist');
      expect(player.snapshot.album, 'Album');
      expect(player.snapshot.hasNext, isFalse);
      expect(player.snapshot.status, PlaybackStatus.playing);
      final paused = await player.execute(
        PlayerCommand.fromJson({'type': 'pause'}),
      );
      expect(paused.status, PlaybackStatus.paused);
      await player.execute(PlayerCommand.fromJson({'type': 'pause'}));
      expect(playback.value.playing, isFalse, reason: 'pause is not a toggle');
      await player.execute(
        PlayerCommand.fromJson({'type': 'seek', 'positionMs': 15000}),
      );
      expect(playback.value.position, const Duration(seconds: 15));
      await player.execute(
        PlayerCommand.fromJson({'type': 'setVolume', 'volume': 0.2}),
      );
      expect(volume.value.level, 20);
      await playback.toggle();
      expect(player.snapshot.status, PlaybackStatus.playing);
      expect(
        states.map((s) => s.revision),
        orderedEquals(states.map((s) => s.revision).toList()..sort()),
      );
      await player.execute(PlayerCommand.fromJson({'type': 'stop'}));
      expect(playback.value.state, PlaybackState.stopped);
      await player.execute(PlayerCommand.fromJson({'type': 'stop'}));
      await player.close();
      expect(player.snapshot.available, isFalse);
    } finally {
      await subscription.cancel();
      await player.close();
      playback.dispose();
      volume.dispose();
    }
  });

  test(
    'video activity makes music API unavailable until that session ends',
    () async {
      final playback = SerializedPlayback(SilentPlayback());
      final volume = VolumeSwitch();
      final player = FlutterPlayerService(playback: playback, volume: volume);
      final video = VideoPlayback();
      try {
        await playback.play(const [track]);
        VideoPlayback.active = video;
        expect(player.snapshot.available, isFalse);
        await expectLater(
          player.execute(PlayerCommand.fromJson({'type': 'play'})),
          throwsA(isA<PlayerFailure>()),
        );
        VideoPlayback.active = null;
        expect(player.snapshot.available, isTrue);
      } finally {
        VideoPlayback.active = null;
        video.dispose();
        await player.close();
        playback.dispose();
        volume.dispose();
      }
    },
  );
}
