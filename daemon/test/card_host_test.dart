import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:daemon_client/daemon_client.dart'
    show DeviceSnapshot, StorageClient;
import 'package:tempod/tempod.dart';
import 'package:tempod/src/services/card_host.dart';
import 'package:tempod/src/services/cadence_roots.dart';
import 'package:test/test.dart';

class Transport implements MediaTransport {
  final calls = <String>[];
  bool released = false, refuse = false;
  String storageKind = 'portable';
  Map<String, Object?> get status => {
    'id': 'library',
    'generation': '1',
    'storageKind': storageKind,
    'pathStyle': 'volume-posix',
    'mediaMount': null,
    'state': released ? 'detached' : 'attached',
    'readyToUnmount': released,
    'rootAvailabilityReady': true,
    'quiescentRootIds': [],
    'quiescentMountPaths': [],
    'activity': {},
  };
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    if (path == '/snapshot') return {'volume': status, 'roots': []};
    if (path == '/volume/roots') calls.add('roots');
    if (path == '/volume/eject') {
      calls.add('release');
      released = !refuse;
    }
    return status;
  }

  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<List<int>?> artwork(int id) async => null;
  @override
  Future<void> close() async {}
}

void main() {
  late Transport transport;
  late CardHost host;
  late CadenceRoots roots;
  late DeviceSnapshot reading;
  bool busy = false, changedDuringDrain = false;
  const request = {
    'action': 'eject',
    'datastoreId': 'library',
    'generation': '1',
    'mountId': '40',
    'cardId': 'card',
  };
  setUp(() {
    busy = false;
    changedDuringDrain = false;
    transport = Transport();
    reading = const DeviceSnapshot(
      cardPath: '/mnt/sd',
      cardMountId: '40',
      cardSourceId: 'card',
    );
    final client = CadenceClient(transport);
    roots = CadenceRoots(client: client, device: () => reading);
    host = CardHost(
      client: client,
      roots: roots,
      device: () => reading,
      refreshDevice: () async {
        if (changedDuringDrain && transport.released) {
          reading = const DeviceSnapshot(
            cardPath: '/mnt/sd',
            cardMountId: '41',
            cardSourceId: 'other',
          );
        }
      },
      unmount: (id) async {
        expect(id, '40');
        expect(transport.released, isTrue);
        transport.calls.add('unmount');
        if (busy) throw StateError('Device is busy');
        reading = const DeviceSnapshot();
      },
      format: (id) async {
        expect(id, 'card');
        expect(transport.calls, contains('roots'));
        transport.calls.add('format');
        reading = const DeviceSnapshot(
          cardPath: '/mnt/sd',
          cardMountId: '41',
          cardSourceId: 'card',
        );
      },
    );
  });
  tearDown(() => roots.close());
  test(
    'authenticated client reaches maintenance; invalid credentials do not',
    () async {
      final player = DemoPlayer();
      final server = PlayerServer(
        player: player,
        token: 'card-test',
        cardHost: host,
      );
      await server.start();
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      Future<Map<String, Object?>> eject(String token) =>
          StorageClient(baseUri: base, token: token).cardMaintenance(
            action: 'eject',
            datastoreId: 'library',
            generation: '1',
            mountId: '40',
            cardId: 'card',
          );
      try {
        await expectLater(eject('wrong'), throwsA(isA<HttpException>()));
        expect(transport.calls, isEmpty);
        expect(await eject('card-test'), {'state': 'ejected'});
        expect(transport.calls, ['release', 'unmount']);
      } finally {
        await server.close();
        await player.close();
      }
    },
  );
  test(
    'releases datastore before unmount and acknowledges a repeated successful request',
    () async {
      expect(await host.execute(request), {'state': 'ejected'});
      expect(await host.execute(request), {'state': 'ejected'});
      expect(transport.calls, ['release', 'unmount']);
    },
  );
  test('busy unmount keeps datastore released for a retry', () async {
    busy = true;
    await expectLater(host.execute(request), throwsStateError);
    expect(transport.released, isTrue);
    busy = false;
    await host.execute(request);
    expect(transport.calls, ['release', 'unmount', 'release', 'unmount']);
  });
  test('unfinished release never reaches hardware', () async {
    transport.refuse = true;
    await expectLater(host.execute(request), throwsStateError);
    expect(transport.calls, ['release']);
  });
  test('card replacement during drain cannot unmount the new card', () async {
    changedDuringDrain = true;
    await expectLater(host.execute(request), throwsStateError);
    expect(transport.calls, ['release']);
  });
  test('stale card or library identities fail before release', () async {
    for (final delta in [
      {'mountId': 'old'},
      {'cardId': 'old'},
      {'datastoreId': 'old'},
      {'generation': 'old'},
    ]) {
      await expectLater(host.execute({...request, ...delta}), throwsStateError);
    }
    expect(transport.calls, isEmpty);
  });
  test('malformed maintenance requests cannot perform hardware work', () async {
    await expectLater(host.execute({'action': 'eject'}), throwsFormatException);
    await expectLater(
      host.execute({...request, 'force': 'true'}),
      throwsFormatException,
    );
    expect(transport.calls, isEmpty);
  });
  test(
    'formatting releases internal-library roots and resumes after remount',
    () async {
      transport.storageKind = 'local';
      expect(await host.execute({...request, 'action': 'format'}), {
        'state': 'formatted',
      });
      expect(transport.calls, ['roots', 'format', 'roots']);
    },
  );
  test('formatting refuses an active card-hosted datastore', () async {
    await expectLater(
      host.execute({...request, 'action': 'format'}),
      throwsStateError,
    );
    expect(transport.calls, isEmpty);
  });
}
