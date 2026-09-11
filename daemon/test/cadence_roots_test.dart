import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:daemon_client/daemon_client.dart' show DeviceSnapshot;
import 'package:tempod/src/services/cadence_roots.dart';
import 'package:test/test.dart';

class _Transport implements MediaTransport {
  int generation = 1;
  bool ready = false, released = false;
  bool staleSnapshot = false;
  bool missingMount = false;
  bool detached = false, refuseEject = false;
  int ejects = 0;
  String? mediaMount = '/mnt/sd';
  String storageKind = 'local';
  final updates = <Map<String, Object?>>[];
  Map<String, Object?> get status => {
    'id': 'store',
    'generation': '$generation',
    'state': detached ? 'detached' : 'attached',
    'storageKind': storageKind,
    'pathStyle': 'volume-posix',
    'mediaMount': mediaMount,
    'rootAvailabilityReady': ready,
    'quiescentRootIds': [],
    'readyToUnmount': detached,
    'activity': {},
    'quiescentMountPaths': released ? ['/mnt/sd'] : [],
  };
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    if (path == '/volume') return status;
    if (path == '/volume/eject') {
      expect(body!['expectedId'], 'store');
      expect(body['expectedGeneration'], '$generation');
      ejects++;
      detached = !refuseEject;
      return status;
    }
    if (path == '/volume/attach') {
      expect(body!['expectedId'], 'store');
      expect(body['expectedGeneration'], '$generation');
      detached = false;
      generation++;
      ready = false;
      return status;
    }
    if (path == '/snapshot') {
      return {
        'volume': {...status, if (staleSnapshot) 'generation': 'stale'},
        'roots': [
          {'id': 1, 'path': '/Podcasts', 'mountPath': mediaMount},
          {
            'id': 2,
            'path': '/Music',
            if (!missingMount) 'mountPath': mediaMount,
          },
        ],
      };
    }
    expect(path, '/volume/roots');
    expect(body!['expectedId'], 'store');
    expect(body['expectedGeneration'], '$generation');
    updates.add(body);
    released = ((body['roots'] as List)[1] as Map)['available'] == false;
    ready = true;
    generation++;
    return status;
  }

  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<List<int>?> artwork(int _) async => null;
  @override
  Future<void> close() async {}
}

void main() {
  late _Transport transport;
  late CadenceRoots bridge;
  var reading = const DeviceSnapshot();
  setUp(() {
    transport = _Transport();
    reading = const DeviceSnapshot(
      cardPath: '/mnt/sd',
      cardMountId: '40',
      cardSourceId: 'card',
    );
    bridge = CadenceRoots(
      client: CadenceClient(transport),
      device: () => reading,
    );
  });
  tearDown(() => bridge.close());
  test(
    'complete root handshake sends physical and mount identities without polling churn',
    () async {
      final result = await bridge.synchronize();
      expect(result.generation, '2');
      expect(transport.updates.single['roots'], [
        {
          'rootId': 1,
          'available': true,
          'mountPath': '/mnt/sd',
          'mountId': '40',
          'sourceId': 'card',
        },
        {
          'rootId': 2,
          'available': true,
          'mountPath': '/mnt/sd',
          'mountId': '40',
          'sourceId': 'card',
        },
      ]);
      await bridge.synchronize();
      expect(transport.updates.length, 1);
      transport.ready = false; // UI added/changed roots.
      await bridge.synchronize();
      expect(transport.updates.length, 2);
    },
  );
  test('path alone never marks a removable root available', () async {
    reading = const DeviceSnapshot(cardPath: '/mnt/sd');
    await bridge.synchronize();
    expect((transport.updates.single['roots'] as List)[1], {
      'rootId': 2,
      'available': false,
      'mountPath': '/mnt/sd',
    });
  });
  test(
    'requested eject remains suppressed through unmount until a new mount',
    () async {
      await bridge.synchronize();
      final result = await bridge.quiesceCard();
      expect(result.quiescentMountPaths, contains('/mnt/sd'));
      expect(transport.released, true);
      await bridge.synchronize();
      expect(transport.released, true);
      reading = const DeviceSnapshot(); // Requested unmount, not new insertion.
      await bridge.synchronize();
      expect(transport.released, true);
      reading = const DeviceSnapshot(
        cardPath: '/mnt/sd',
        cardMountId: '41',
        cardSourceId: 'card',
      );
      await bridge.synchronize();
      expect(transport.released, false);
    },
  );
  test(
    'explicit resume releases suppression after failed OS unmount',
    () async {
      await bridge.quiesceCard();
      expect(transport.released, true);
      await bridge.resumeCard();
      expect(transport.released, false);
    },
  );
  test('SD roots without explicit mount metadata are rejected', () async {
    transport.missingMount = true;
    await expectLater(bridge.synchronize(), throwsFormatException);
    expect(transport.updates, isEmpty);
  });
  test('home-rooted datastore uses home when no SD is configured', () async {
    transport.mediaMount = null;
    reading = const DeviceSnapshot();
    await bridge.synchronize();
    expect(transport.updates.single['roots'], [
      {'rootId': 1, 'available': true},
      {'rootId': 2, 'available': true},
    ]);
  });
  test(
    'SD metadata also completes the root handshake before media work',
    () async {
      transport.storageKind = 'portable';
      await bridge.synchronize();
      expect(transport.updates, hasLength(1));
    },
  );
  test('stale snapshot is rejected before any root mutation', () async {
    transport.staleSnapshot = true;
    await expectLater(bridge.synchronize(), throwsStateError);
    expect(transport.updates, isEmpty);
  });
  test(
    'card metadata requires full eject rather than just unavailable roots',
    () async {
      transport.storageKind = 'portable';
      final result = await bridge.quiesceCard(
        expectedId: 'store',
        expectedGeneration: '1',
      );
      expect(result.readyToUnmount, isTrue);
      expect(transport.ejects, 1);
      expect(transport.updates, isEmpty);
    },
  );
  test('unfinished card datastore drain is not acknowledged', () async {
    transport.storageKind = 'portable';
    transport.refuseEject = true;
    await expectLater(bridge.quiesceCard(), throwsStateError);
  });
  test(
    'home media stays available while ejecting an unrelated SD card',
    () async {
      transport.mediaMount = null;
      final result = await bridge.quiesceCard();
      expect(result.state, 'attached');
      expect(transport.ejects, 0);
      expect(
        (transport.updates.single['roots'] as List).every(
          (row) => (row as Map)['available'] == true,
        ),
        isTrue,
      );
    },
  );
  test('stale eject request cannot quiesce the current datastore', () async {
    await expectLater(
      bridge.quiesceCard(expectedId: 'other', expectedGeneration: '1'),
      throwsStateError,
    );
    expect(transport.ejects, 0);
    expect(transport.updates, isEmpty);
  });
  test(
    'resume after a failed unmount reattaches and handshakes card metadata',
    () async {
      transport.storageKind = 'portable';
      await bridge.quiesceCard();
      final result = await bridge.resumeCard();
      expect(result.state, 'attached');
      expect(result.rootAvailabilityReady, isTrue);
      expect(result.generation, '3');
      expect(transport.updates, hasLength(1));
    },
  );
}
