import 'dart:async';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:daemon_client/daemon_client.dart' show DeviceSnapshot;
import 'package:tempod/src/services/cadence_roots.dart';
import 'package:tempod/src/services/cadence_coordinator.dart';
import 'package:test/test.dart';

class _Transport implements MediaTransport {
  _Transport(this.home);
  final String home;
  bool ready = false;
  int generation = 1;
  final libraries = <Map<String, Object?>>[];
  final roots = <Map<String, Object?>>[];
  final calls = <String>[];
  Map<String, Object?> get volume => {
    'id': 'store',
    'generation': '$generation',
    'state': 'attached',
    'storageKind': 'local',
    'pathStyle': 'volume-posix',
    'resolvedMediaRoot': home,
    'mediaRoot': '.',
    'mediaMount': null,
    'rootAvailabilityReady': ready,
    'quiescentRootIds': [],
    'quiescentMountPaths': [],
    'readyToUnmount': false,
    'activity': {},
  };
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    calls.add('$method $path');
    if (path == '/volume') return volume;
    if (path == '/snapshot') return {'volume': volume, 'roots': roots};
    if (path == '/volume/roots') {
      ready = true;
      generation++;
      return volume;
    }
    if (path == '/libraries') {
      if (method == 'get') return {'libraries': libraries};
      final id = libraries.length + 1;
      libraries.add({'id': id, 'uuid': 'library$id', ...body!});
      return {'id': id, 'uuid': 'library$id'};
    }
    final parts = path.split('/');
    final id = int.parse(parts[2]);
    if (parts[3] == 'roots') {
      if (method == 'get')
        return {'roots': roots.where((r) => r['libraryId'] == id).toList()};
      if (method == 'delete') {
        roots.removeWhere((r) => r['id'] == int.parse(parts[4]));
        ready = false;
        return {};
      }
      final rootId = roots.length + 1;
      roots.add({
        'id': rootId,
        'libraryId': id,
        'path': body!['path'],
        'mountPath': null,
      });
      ready = false;
      return {'id': rootId};
    }
    throw StateError('Unexpected $method $path');
  }

  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<List<int>?> artwork(int _) async => null;
  @override
  Future<void> close() async {}
}

void main() {
  late Directory home;
  late _Transport transport;
  late CadenceCoordinator coordinator;
  setUp(() {
    home = Directory.systemTemp.createTempSync('cadence-policy-');
    Directory('${home.path}/Music').createSync();
    transport = _Transport(home.path);
    final client = CadenceClient(transport);
    coordinator = CadenceCoordinator(
      client,
      roots: CadenceRoots(client: client, device: () => const DeviceSnapshot()),
      log: (_) {},
    );
  });
  tearDown(() async {
    await coordinator.close();
    home.deleteSync(recursive: true);
  });
  test(
    'creates sections and relative roots then completes availability',
    () async {
      await coordinator.start({});
      expect(transport.libraries, hasLength(6));
      expect(transport.roots.single['path'], '/Music');
      expect(transport.ready, true);
      expect(transport.calls.last, 'post /volume/roots');
      expect(transport.calls.where((c) => c.endsWith('/scan')), isEmpty);
    },
  );
  test(
    'missing media does not remove roots; an explicit setting can',
    () async {
      await coordinator.start({});
      Directory('${home.path}/Music').deleteSync();
      await coordinator.observeCard();
      expect(transport.roots, hasLength(1));
      await coordinator.configure({
        '/settings/library/roots': {'music': <String>[]},
      });
      expect(transport.roots, isEmpty);
    },
  );
}
