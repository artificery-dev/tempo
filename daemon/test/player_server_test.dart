import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:player_api/player_api.dart';
import 'package:tempod/tempod.dart';
import 'package:test/test.dart';

void main() {
  late DemoPlayer player;
  late PlayerServer server;
  late HttpClient http;
  const token = 'test-token-that-is-not-a-real-secret';
  setUp(() async {
    player = DemoPlayer();
    server = PlayerServer(player: player, token: token);
    await server.start();
    http = HttpClient();
  });
  tearDown(() async {
    http.close(force: true);
    await server.close();
    await player.close();
  });

  Future<(int, Map<String, dynamic>)> request(
    String path, {
    String method = 'GET',
    String? bearer = token,
    Object? body,
    String? raw,
    String? origin,
    String contentType = 'application/json',
  }) async {
    final req = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (bearer != null) req.headers.set('authorization', 'Bearer $bearer');
    if (origin != null) req.headers.set('origin', origin);
    if (body != null || raw != null) {
      req.headers.set('content-type', contentType);
      req.write(raw ?? jsonEncode(body));
    }
    final res = await req.close();
    expect(res.headers.value('cache-control'), 'no-store');
    return (
      res.statusCode,
      jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>,
    );
  }

  Future<WebSocket> connect({String bearer = token, String? origin}) =>
      WebSocket.connect(
        'ws://127.0.0.1:${server.port}/api/v1/events',
        headers: {'authorization': 'Bearer $bearer', 'origin': ?origin},
      );

  test('REST changes the same state exposed by the player service', () async {
    final initial = await request('/api/v1/player');
    expect(initial.$1, 200);
    expect(initial.$2['status'], 'paused');
    final played = await request(
      '/api/v1/commands',
      method: 'POST',
      body: {'type': 'play'},
    );
    expect(played.$1, 200);
    expect(played.$2['state']['revision'], 1);
    expect(player.snapshot.status, PlaybackStatus.playing);
    final seek = await request(
      '/api/v1/commands',
      method: 'POST',
      body: {'type': 'seek', 'positionMs': 200000},
    );
    expect(seek.$2['state']['positionMs'], 180000);
    expect((await request('/api/v1/player')).$2['revision'], 2);
  });

  test(
    'authentication and origin policy apply before HTTP or WebSocket work',
    () async {
      expect((await request('/api/v1/player', bearer: null)).$1, 401);
      expect(
        (await request(
          '/api/v1/commands',
          method: 'POST',
          bearer: 'wrong',
          body: {'type': 'play'},
        )).$1,
        401,
      );
      expect(
        (await request('/api/v1/player?token=$token', bearer: null)).$1,
        401,
      );
      expect(
        (await request('/api/v1/player', origin: 'https://untrusted.test')).$1,
        403,
      );
      await expectLater(
        connect(bearer: 'wrong'),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        connect(origin: 'https://untrusted.test'),
        throwsA(isA<WebSocketException>()),
      );
      expect(player.snapshot.revision, 0);
      expect(server.clientCount, 0);
    },
  );

  test('invalid and oversized input never reaches the player', () async {
    expect(
      (await request('/api/v1/commands', method: 'POST', raw: '{')).$1,
      400,
    );
    expect(
      (await request(
        '/api/v1/commands',
        method: 'POST',
        body: {'type': 'setVolume', 'volume': 8},
      )).$1,
      400,
    );
    expect(
      (await request(
        '/api/v1/commands',
        method: 'POST',
        body: {'type': 'play'},
        contentType: 'text/plain',
      )).$1,
      415,
    );
    expect(
      (await request(
        '/api/v1/commands',
        method: 'POST',
        raw: 'x' * (PlayerServer.maxBodyBytes + 1),
      )).$1,
      413,
    );
    expect((await request('/api/v1/missing')).$1, 404);
    expect((await request('/api/v1/events')).$1, 400);
    expect(player.snapshot.revision, 0);
  });

  test(
    'event snapshots are ordered and coalesced until acknowledged',
    () async {
      final socket = await connect();
      final events = StreamIterator(socket);
      addTearDown(events.cancel);
      addTearDown(socket.close);
      expect(await events.moveNext(), isTrue);
      final first = jsonDecode(events.current as String);
      expect(first['type'], 'snapshot');
      expect(first['state']['revision'], 0);
      for (var i = 0; i < 3; i++) {
        await request(
          '/api/v1/commands',
          method: 'POST',
          body: {'type': 'toggle'},
        );
      }
      socket.add(jsonEncode({'type': 'ack', 'revision': 0}));
      expect(await events.moveNext(), isTrue);
      final latest = jsonDecode(events.current as String);
      expect(latest['state']['revision'], 3);
      expect(latest['state']['status'], 'playing');
      socket.add(jsonEncode({'type': 'ack', 'revision': 3}));
      await server.close();
      expect(await events.moveNext(), isFalse);
      expect(server.clientCount, 0);
    },
  );

  test('new connections receive current state, not stale replay', () async {
    await request('/api/v1/commands', method: 'POST', body: {'type': 'play'});
    final socket = await connect();
    expect(jsonDecode(await socket.first as String)['state']['revision'], 1);
    await socket.close();
  });

  test('invalid acknowledgement closes only its own connection', () async {
    final socket = await connect();
    final messages = <dynamic>[];
    final closed = Completer<void>();
    socket.listen(messages.add, onDone: closed.complete);
    socket.add('{"type":"ack","revision":999}');
    await closed.future.timeout(const Duration(seconds: 60));
    expect(socket.closeCode, 4002);
    expect((await request('/api/v1/player')).$1, 200);
  });

  test(
    'unacknowledged clients expire and release the connection slot',
    () async {
      await server.close();
      server = PlayerServer(
        player: player,
        token: token,
        // Long enough that a second handshake cannot outlive it on a busy
        // machine, which would free the slot this test needs occupied.
        ackTimeout: const Duration(seconds: 5),
        maxClients: 1,
      );
      await server.start();
      final socket = await connect();
      final events = StreamIterator(socket);
      expect(await events.moveNext(), isTrue);
      await expectLater(connect(), throwsA(isA<WebSocketException>()));
      expect(
        await events.moveNext().timeout(const Duration(seconds: 60)),
        isFalse,
      );
      expect(socket.closeCode, 4008);
      expect(server.clientCount, 0);
      await events.cancel();
    },
  );

  test(
    'disconnected backend returns a structured unavailable response',
    () async {
      await server.close();
      server = PlayerServer(player: const UnavailablePlayer(), token: token);
      await server.start();
      final response = await request(
        '/api/v1/commands',
        method: 'POST',
        body: {'type': 'play'},
      );
      expect(response.$1, 503);
      expect(response.$2['error']['code'], 'player_unavailable');
      expect((await request('/api/v1/player')).$2['available'], isFalse);
    },
  );

  test(
    'explicit allowed origins work without enabling arbitrary origins',
    () async {
      await server.close();
      server = PlayerServer(
        player: player,
        token: token,
        allowedOrigins: {'https://controller.test'},
      );
      await server.start();
      expect(
        (await request('/api/v1/player', origin: 'https://controller.test')).$1,
        200,
      );
      final socket = await connect(origin: 'https://controller.test');
      await socket.first;
      await socket.close();
    },
  );

  test(
    'backend format errors are internal failures, not client errors',
    () async {
      await server.close();
      final backend = _FailingPlayer();
      addTearDown(backend.close);
      server = PlayerServer(player: backend, token: token);
      await server.start();
      final response = await request(
        '/api/v1/commands',
        method: 'POST',
        body: {'type': 'play'},
      );
      expect(response.$1, 500);
      expect(response.$2['error']['code'], 'internal_error');
      expect(jsonEncode(response.$2), isNot(contains('private backend data')));
    },
  );

  test(
    'failed initial snapshot releases the subscription and client slot',
    () async {
      await server.close();
      final backend = _FailingPlayer(failSnapshot: true);
      addTearDown(backend.close);
      server = PlayerServer(player: backend, token: token, maxClients: 1);
      await server.start();
      for (var attempt = 0; attempt < 2; attempt++) {
        final socket = await connect();
        await socket.drain<void>().timeout(const Duration(seconds: 60));
        expect(socket.closeCode, 4004);
        expect(server.clientCount, 0);
        expect(backend.states.hasListener, isFalse);
      }
    },
  );
}

final class _FailingPlayer implements PlayerService {
  _FailingPlayer({this.failSnapshot = false});
  final bool failSnapshot;
  final states = StreamController<PlayerSnapshot>.broadcast();

  @override
  PlayerSnapshot get snapshot {
    if (failSnapshot) throw const FormatException('private backend data');
    return const PlayerSnapshot(revision: 0, available: true);
  }

  @override
  Stream<PlayerSnapshot> get changes => states.stream;

  @override
  Future<PlayerSnapshot> execute(PlayerCommand command) async =>
      throw const FormatException('private backend data');

  Future<void> close() => states.close();
}
