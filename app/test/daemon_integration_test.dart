import 'dart:convert';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player_api/player_api.dart';
import 'package:tempo/src/flutter_player_service.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempod/tempod.dart';
import 'package:tempod/src/services/remote_player.dart';

void main() {
  test(
    'REST commands drive the same Flutter player that local UI controls',
    () async {
      final playback = SerializedPlayback(SilentPlayback());
      final volume = VolumeSwitch();
      final player = FlutterPlayerService(playback: playback, volume: volume);
      final proxy = RemotePlayer();
      final server = PlayerServer(
        player: proxy,
        token: 'api-test',
        ownerToken: 'owner-test',
      );
      await server.start();
      final owner = PlaybackOwnerConnection(
        uri: Uri.parse('ws://127.0.0.1:${server.port}/api/v1/owner'),
        token: 'owner-test',
        player: player,
      );
      final http = HttpClient();
      try {
        await playback.play(const [
          TrackSummary(
            id: 1,
            fileId: 1,
            path: '/music/test.ogg',
            title: 'Track',
          ),
        ]);
        final attached = proxy.changes.firstWhere((s) => s.available);
        owner.start();
        await attached.timeout(const Duration(seconds: 60));
        final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/v1/commands'),
        );
        request.headers.set('authorization', 'Bearer api-test');
        request.headers.contentType = ContentType.json;
        request.write('{"type":"pause"}');
        final response = await request.close();
        expect(response.statusCode, 200);
        final state = jsonDecode(
          await response.transform(utf8.decoder).join(),
        )['state'];
        expect(state['status'], 'paused');
        expect(playback.value.playing, isFalse);
        final moved = proxy.changes.firstWhere(
          (s) => s.status == PlaybackStatus.playing,
        );
        await playback.toggle();
        await moved.timeout(const Duration(seconds: 60));
        final disconnected = proxy.changes.firstWhere((s) => !s.available);
        await owner.close();
        await disconnected.timeout(const Duration(seconds: 60));
        expect(
          playback.value.playing,
          isTrue,
          reason: 'Daemon loss does not create or stop a second player.',
        );
      } finally {
        http.close(force: true);
        await owner.close();
        await server.close();
        await proxy.close();
        await player.close();
        playback.dispose();
        volume.dispose();
      }
    },
  );
}
