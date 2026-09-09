import 'dart:convert';
import 'dart:io';

import 'package:cadence_media/cadence_media.dart';
import 'package:daemon_client/daemon_client.dart';
import 'package:tempod/src/services/media_host.dart';
import 'package:tempod/tempod.dart';
import 'package:test/test.dart';

void main() {
  test('library persists across UI clients and daemon restarts', () async {
    final directory = await Directory.systemTemp.createTemp('tempod-media-');
    final database = '${directory.path}/library.db';
    Future<void> visit({required bool create}) async {
      final media = await MediaHost.open(database);
      final player = DemoPlayer();
      final server = PlayerServer(
        player: player,
        token: 'media-test',
        mediaHost: media,
      );
      await server.start();
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      final first = MediaTransport(baseUri: base, token: 'media-test');
      final client = MediaClient(first.send, onClose: first.close);
      try {
        if (create) await client.createLibrary('Music', LibraryType.music);
        expect(
          (await client.listLibraries()).map((v) => v.name),
          contains('Music'),
        );
        await client.close();
        final next = MediaTransport(baseUri: base, token: 'media-test');
        final reconnected = MediaClient(next.send, onClose: next.close);
        expect(
          (await reconnected.listLibraries()).map((v) => v.name),
          contains('Music'),
        );
        await reconnected.close();
        final unauthorized = MediaTransport(baseUri: base, token: 'wrong');
        await expectLater(
          unauthorized.send({'id': 1, 'method': 'get', 'path': '/libraries'}),
          throwsA(isA<HttpException>()),
        );
        await unauthorized.close();
        final http = HttpClient();
        final request = await http.postUrl(base.resolve('/api/v1/media'));
        request.headers.set('authorization', 'Bearer media-test');
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({'id': 1, 'method': 'invalid', 'path': '/libraries'}),
        );
        final response = await request.close();
        expect(response.statusCode, 400);
        await response.drain<void>();
        http.close(force: true);
      } finally {
        await client.close();
        await server.close();
        await media.close();
        await player.close();
      }
    }

    try {
      await visit(create: true);
      await visit(create: false);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
