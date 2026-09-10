import 'dart:io';
import 'package:tempod/tempod.dart';
import 'package:test/test.dart';

void main() {
  test(
    'tempod exposes hardware but no media proxy or embedded scanner',
    () async {
      final player = DemoPlayer();
      final server = PlayerServer(player: player, token: 'media-test');
      await server.start();
      final http = HttpClient();
      try {
        final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/v1/media'),
        );
        request.headers.set('authorization', 'Bearer media-test');
        final response = await request.close();
        expect(response.statusCode, 404);
        await response.drain<void>();
      } finally {
        http.close(force: true);
        await server.close();
        await player.close();
      }
    },
  );
}
