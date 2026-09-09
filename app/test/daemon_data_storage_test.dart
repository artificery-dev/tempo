import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player_api/player_api.dart';
import 'package:tempo/src/daemon_data_storage.dart';
import 'package:tempo_core/tempo_core.dart';

StorageStatus status({String policy = 'ask', bool pending = false}) =>
    StorageStatus(
      policy: policy,
      location: 'device',
      available: true,
      mediaHome: '/home/tempo',
      dataPath: '/home/tempo/.tempo',
      configPath: '/home/tempo/.config/tempo',
      sdAvailable: true,
      needsPrompt: true,
      restartPending: pending,
      deviceProfileExists: true,
      sdProfileExists: true,
    );

void main() {
  late HttpServer server;
  late DaemonDataStorage controller;
  final bodies = <Map<String, dynamic>>[];
  var reject = false;
  setUp(() async {
    bodies.clear();
    reject = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer test');
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      bodies.add(body);
      request.response.statusCode = reject ? 409 : 202;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          reject
              ? {'error': 'conflict'}
              : status(
                  policy: body['policy'] as String? ?? 'ask',
                  pending: true,
                ).toJson(),
        ),
      );
      await request.response.close();
    });
    controller = DaemonDataStorage(
      StorageClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'test',
      ),
      status(),
    );
  });
  tearDown(() async {
    controller.dispose();
    await server.close(force: true);
  });

  test(
    'flush completes before selection and duplicate changes cannot race it',
    () async {
      final flush = Completer<void>();
      controller.beforeChange = () => flush.future;
      final changing = controller.adoptCardForStartup();
      await controller.setPolicy(DataStoragePolicy.no);
      expect(bodies, isEmpty);
      flush.complete();
      await changing;
      expect(bodies, hasLength(1));
      expect(bodies.single, {
        'policy': 'yes',
        'adoptExisting': true,
        'replaceExisting': false,
      });
      expect(controller.value.restarting, isTrue);
      expect(
        controller.value.usingCard,
        isFalse,
        reason: 'Accepted selection is not an active profile yet',
      );
    },
  );

  test('failed flush cannot reach server or change active profile', () async {
    controller.beforeChange = () async => throw StateError('disk full');
    await expectLater(
      controller.setPolicy(DataStoragePolicy.yes),
      throwsStateError,
    );
    expect(bodies, isEmpty);
    expect(controller.value.policy, DataStoragePolicy.ask);
    expect(controller.value.busy, isFalse);
    expect(controller.value.error, contains('disk full'));
  });

  test(
    'server rejection keeps active profile and permits an explicit retry',
    () async {
      reject = true;
      await expectLater(
        controller.setPolicy(DataStoragePolicy.yes),
        throwsA(isA<HttpException>()),
      );
      expect(controller.value.policy, DataStoragePolicy.ask);
      expect(controller.value.restarting, isFalse);
      reject = false;
      await controller.setPolicy(DataStoragePolicy.yes, replaceExisting: true);
      expect(bodies.last['replaceExisting'], isTrue);
      expect(controller.value.restarting, isTrue);
    },
  );
}
