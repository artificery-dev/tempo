import 'package:player_api/player_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'additive AVRCP metadata accepts old snapshots and validates new fields',
    () {
      final old = const PlayerSnapshot(revision: 1, available: true).toJson()
        ..remove('artist')
        ..remove('album')
        ..remove('hasNext');
      final decoded = PlayerSnapshot.fromJson(old);
      expect(decoded.artist, isNull);
      expect(decoded.album, isNull);
      expect(decoded.hasNext, isFalse);
      final enriched = {
        ...old,
        'artist': 'Artist',
        'album': 'Album',
        'hasNext': true,
      };
      final state = PlayerSnapshot.fromJson(enriched);
      expect(state.toJson(), enriched);
      for (final field in ['artist', 'album', 'hasNext']) {
        expect(
          () => PlayerSnapshot.fromJson({...old, field: 123}),
          throwsFormatException,
        );
      }
    },
  );

  test('commands round trip without transport-specific fields', () {
    for (final command in [
      {'type': 'play'},
      {'type': 'pause'},
      {'type': 'stop'},
      {'type': 'toggle'},
      {'type': 'next'},
      {'type': 'previous'},
      {'type': 'seek', 'positionMs': 1250},
      {'type': 'setVolume', 'volume': 0.5},
    ]) {
      expect(PlayerCommand.fromJson(command).toJson(), command);
    }
  });

  test('rejects malformed commands and out-of-range values', () {
    for (final input in <Object?>[
      null,
      [],
      'play',
      {},
      {'type': 'launch'},
      {'type': 'play', 'path': '/bin/sh'},
      {'type': 'seek'},
      {'type': 'seek', 'positionMs': -1},
      {'type': 'seek', 'positionMs': 1.5},
      {'type': 'setVolume', 'volume': double.nan},
      {'type': 'setVolume', 'volume': double.infinity},
      {'type': 'setVolume', 'volume': -0.1},
      {'type': 'setVolume', 'volume': 1.1},
      {'type': 'setVolume', 'volume': '0.5'},
    ]) {
      expect(
        () => PlayerCommand.fromJson(input),
        throwsFormatException,
        reason: '$input',
      );
    }
  });

  test(
    'disconnected player reports unavailable rather than accepting commands',
    () async {
      const player = UnavailablePlayer();
      expect(player.snapshot.available, isFalse);
      expect(await player.changes.toList(), isEmpty);
      await expectLater(
        player.execute(PlayerCommand.fromJson({'type': 'play'})),
        throwsA(
          isA<PlayerFailure>().having(
            (e) => e.code,
            'code',
            'player_unavailable',
          ),
        ),
      );
    },
  );
  test(
    'snapshot decoding validates fields while allowing future additions',
    () {
      const state = PlayerSnapshot(
        revision: 3,
        available: true,
        status: PlaybackStatus.playing,
        trackId: 'library:1',
        title: 'Track',
        positionMs: 200,
        durationMs: 3000,
        volume: 0.5,
      );
      expect(
        PlayerSnapshot.fromJson({...state.toJson(), 'future': true}).toJson(),
        state.toJson(),
      );
      for (final invalid in [
        {'revision': -1},
        {'available': 'yes'},
        {'status': 'unknown'},
        {'positionMs': -1},
        {'durationMs': 0.1},
        {'volume': double.infinity},
        {'title': 3},
      ]) {
        expect(
          () => PlayerSnapshot.fromJson({...state.toJson(), ...invalid}),
          throwsFormatException,
        );
      }
    },
  );
}
