import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';
import 'package:player_api/player_api.dart';
import 'package:tempod/tempod.dart';
import 'package:tempod/src/services/remote_player.dart';
import 'package:test/test.dart';

/// Waits for a condition rather than a duration. The budget is a guard
/// against a hang, not a statement about speed: a host building several jobs
/// at once takes its time over a socket round trip.
Future<void> eventually(bool Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 60));
  while (!condition()) {
    if (DateTime.now().isAfter(until)) {
      fail('Timed out waiting for owner state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'real owner bridge authenticates, forwards commands, syncs, and reconnects',
    () async {
      final player = DemoPlayer();
      final proxy = RemotePlayer();
      var server = PlayerServer(
        player: proxy,
        token: 'remote-token',
        ownerToken: 'owner-token',
      );
      await server.start();
      final port = server.port;
      final uri = Uri.parse('ws://127.0.0.1:$port/api/v1/owner');
      final readiness = <bool>[];
      final owner = PlaybackOwnerConnection(
        uri: uri,
        token: 'owner-token',
        player: player,
        onBluetoothPlaybackReady: readiness.add,
        retryDelay: const Duration(milliseconds: 100),
      );
      final http = HttpClient();
      try {
        await expectLater(
          WebSocket.connect(
            uri.toString(),
            headers: {'authorization': 'Bearer remote-token'},
          ),
          throwsA(isA<WebSocketException>()),
        );
        owner.start();
        await eventually(() => proxy.snapshot.available);
        await expectLater(
          WebSocket.connect(
            uri.toString(),
            headers: {'authorization': 'Bearer owner-token'},
          ),
          throwsA(isA<WebSocketException>()),
        );
        final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/v1/commands'),
        );
        request.headers.set('authorization', 'Bearer remote-token');
        request.headers.contentType = ContentType.json;
        request.write('{"type":"play"}');
        final response = await request.close();
        expect(response.statusCode, 200);
        expect(
          jsonDecode(
            await response.transform(utf8.decoder).join(),
          )['state']['status'],
          'playing',
        );
        expect(player.snapshot.status, PlaybackStatus.playing);
        proxy.notifyBluetoothPlaybackReady(true);
        await eventually(() => readiness.isNotEmpty && readiness.last);

        await player.execute(PlayerCommand.fromJson({'type': 'pause'}));
        expect(readiness.last, isFalse);
        proxy.notifyBluetoothPlaybackReady(true);
        // Wait for something that does arrive before asserting the stale
        // readiness never did, so a slow machine cannot pass this vacuously.
        await eventually(() => proxy.snapshot.status == PlaybackStatus.paused);
        expect(
          readiness.last,
          isFalse,
          reason: 'old daemon revision cannot undo local pause',
        );
        final transitions = <PlaybackStatus>[];
        final observation = proxy.changes.listen(
          (s) => transitions.add(s.status),
        );
        await player.execute(PlayerCommand.fromJson({'type': 'play'}));
        await player.execute(PlayerCommand.fromJson({'type': 'pause'}));
        await player.execute(PlayerCommand.fromJson({'type': 'play'}));
        await eventually(() => transitions.length >= 3);
        expect(transitions.take(3), [
          PlaybackStatus.playing,
          PlaybackStatus.paused,
          PlaybackStatus.playing,
        ]);
        await observation.cancel();
        final revision = proxy.snapshot.revision;
        await server.close();
        await eventually(() => readiness.last == false);
        expect(proxy.snapshot.available, isFalse);
        server = PlayerServer(
          player: proxy,
          token: 'remote-token',
          ownerToken: 'owner-token',
        );
        // The owner reconnects to the address it knows, so the new server has
        // to take the old one's port back. The kernel can still be holding it
        // for a moment after the close, which is not a failure to bind.
        final rebind = DateTime.now().add(const Duration(seconds: 60));
        while (true) {
          try {
            await server.start(port: port);
            break;
          } on SocketException {
            if (DateTime.now().isAfter(rebind)) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        await eventually(() => proxy.snapshot.available);
        expect(proxy.snapshot.revision, greaterThan(revision));
        expect(readiness.last, isFalse);
        proxy.notifyBluetoothPlaybackReady(true);
        await eventually(() => readiness.last);
        await owner.close();
        await eventually(() => !proxy.snapshot.available);
      } finally {
        http.close(force: true);
        await owner.close();
        await server.close();
        await proxy.close();
        await player.close();
      }
    },
  );

  test(
    'disconnect fails pending command and stale sessions cannot change state',
    () async {
      final proxy = RemotePlayer();
      proxy.attach(
        const PlayerSnapshotEmitted(
          sessionId: 'one',
          state: PlayerSnapshot(revision: 0, available: true),
        ),
        (_) {},
      );
      final pending = proxy.execute(PlayerCommand.fromJson({'type': 'play'}));
      final failed = expectLater(pending, throwsA(isA<PlayerFailure>()));
      proxy.detach();
      await failed;
      proxy.attach(
        const PlayerSnapshotEmitted(
          sessionId: 'two',
          state: PlayerSnapshot(revision: 0, available: true),
        ),
        (_) {},
      );
      proxy.receive(
        const PlayerSnapshotEmitted(
          sessionId: 'one',
          state: PlayerSnapshot(revision: 99, available: false),
        ),
      );
      expect(proxy.snapshot.available, isTrue);
      await proxy.close();
    },
  );

  test(
    'unknown command outcome retains the slot until a result arrives',
    () async {
      final proxy = RemotePlayer(
        commandTimeout: const Duration(milliseconds: 20),
      );
      PlayerCommandRequested? request;
      proxy.attach(
        const PlayerSnapshotEmitted(
          sessionId: 'one',
          state: PlayerSnapshot(revision: 0, available: true),
        ),
        (event) => request = event as PlayerCommandRequested,
      );
      await expectLater(
        proxy.execute(PlayerCommand.fromJson({'type': 'toggle'})),
        throwsA(
          isA<PlayerFailure>().having((e) => e.code, 'code', 'command_timeout'),
        ),
      );
      await expectLater(
        proxy.execute(PlayerCommand.fromJson({'type': 'toggle'})),
        throwsA(
          isA<PlayerFailure>().having((e) => e.code, 'code', 'player_busy'),
        ),
      );
      proxy.receive(
        PlayerCommandSucceeded(
          sessionId: 'one',
          requestId: request!.requestId,
          state: const PlayerSnapshot(
            revision: 1,
            available: true,
            status: PlaybackStatus.playing,
          ),
        ),
      );
      expect(proxy.snapshot.status, PlaybackStatus.playing);
      await proxy.close();
    },
  );
}
