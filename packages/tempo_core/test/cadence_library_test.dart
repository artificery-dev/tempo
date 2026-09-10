import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/src/services/cadence_library.dart';

class _Transport implements MediaTransport {
  final stream = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final resolving = Completer<void>();
  final result = Completer<Map<String, Object?>>();
  Map<String, Object?>? body;
  final operations = <String>[];
  bool ejectReady = true;
  bool stale = false;
  String mountedGeneration = 'mount1';
  @override
  Stream<Map<String, Object?>> get events => stream.stream;
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    operations.add(path);
    if (path == '/volume/eject') {
      this.body = body;
      if (stale) throw MediaError('stale_generation', 'Card changed', 409);
      return {
        'storageKind': 'portable',
        'rootAvailabilityReady': true,
        'quiescentRootIds': [],
        'quiescentMountPaths': [],
        'activity': {},
        'id': 'volume',
        'generation': 'mount1',
        'state': ejectReady ? 'detached' : 'unavailable',
        'readyToUnmount': ejectReady,
      };
    }
    if (path == '/volume/attach') return {'state': 'attached'};
    if (path == '/volume') {
      return {
        'storageKind': 'portable',
        'rootAvailabilityReady': true,
        'quiescentRootIds': [],
        'quiescentMountPaths': [],
        'activity': {},
        'readyToUnmount': false,
        'id': 'volume',
        'generation': mountedGeneration,
        'state': 'attached',
      };
    }
    this.body = body;
    resolving.complete();
    return result.future;
  }

  void complete({String generation = 'mount1'}) => result.complete({
    'volumeId': 'volume',
    'generation': generation,
    'libraryUuid': 'library',
    'itemId': 4,
    'path': '/proc/123/fd/9/Music/song.mp3',
  });
  @override
  Future<List<int>?> artwork(int _) async => null;
  @override
  Future<void> close() => stream.close();
}

void main() {
  late _Transport transport;
  late CadenceLibrary library;
  setUp(() async {
    transport = _Transport();
    library = CadenceLibrary(CadenceClient(transport));
    await library.connect();
  });
  tearDown(() async {
    await library.close();
    await transport.close();
  });
  test(
    'polling a new generation invalidates an older resolution even without events',
    () async {
      final pending = library.resolve('library', 4);
      await transport.resolving.future;
      transport.mountedGeneration = 'mount2';
      await library.refresh();
      final rejected = expectLater(pending, throwsStateError);
      transport.complete();
      await rejected;
    },
  );
  test(
    'activity events update busy state without a polling feedback loop',
    () async {
      final count = transport.operations.length;
      final idle = <String, Object?>{
        'type': 'volume-activity',
        'storageKind': 'portable',
        'rootAvailabilityReady': true,
        'quiescentRootIds': [],
        'quiescentMountPaths': [],
        'readyToUnmount': false,
        'id': 'volume',
        'generation': 'mount1',
        'state': 'attached',
        'activity': {
          'activeReadRequests': 0,
          'activeWriteRequests': 0,
          'runningJobs': 0,
          'queuedJobs': 0,
          'draining': false,
          'artwork': {'running': false, 'pending': 0},
        },
      };
      transport.stream.add(idle);
      expect(library.cadenceBusy, false);
      transport.stream.add({
        ...idle,
        'activity': {
          ...idle['activity'] as Map<String, Object?>,
          'queuedJobs': 1,
        },
      });
      expect(library.cadenceBusy, true);
      expect(transport.operations.length, count);
      library.invalidate();
      expect(library.cadenceBusy, true);
    },
  );
  test('eject gates playback and detaches before hardware unmount', () async {
    await library.eject(
      stopPlayback: () async {
        expect(library.canResolve, false);
        transport.operations.add('stop');
      },
      unmount: () async {
        transport.operations.add('unmount');
      },
    );
    expect(transport.operations.sublist(transport.operations.length - 3), [
      'stop',
      '/volume/eject',
      'unmount',
    ]);
    expect(transport.body, {
      'expectedId': 'volume',
      'expectedGeneration': 'mount1',
    });
    expect(library.canResolve, false);
  });
  test('Cadence errors never call hardware unmount', () async {
    transport.ejectReady = false;
    var unmounted = false;
    await expectLater(
      library.eject(
        stopPlayback: () async {},
        unmount: () async {
          unmounted = true;
        },
      ),
      throwsStateError,
    );
    expect(unmounted, false);
    expect(library.canResolve, false);
  });
  test(
    'failed unmount remains blocked, retries with original identity',
    () async {
      await expectLater(
        library.eject(
          stopPlayback: () async {},
          unmount: () async {
            throw StateError('busy');
          },
        ),
        throwsStateError,
      );
      expect(library.canResolve, false);
      transport.stale = true;
      var unmounted = false;
      await expectLater(
        library.eject(
          stopPlayback: () async {},
          unmount: () async {
            unmounted = true;
          },
        ),
        throwsA(isA<MediaError>()),
      );
      expect(unmounted, false);
    },
  );
  test('explicit resume reattaches before allowing playback again', () async {
    await expectLater(
      library.eject(
        stopPlayback: () async {},
        unmount: () async {
          throw StateError('busy');
        },
      ),
      throwsStateError,
    );
    await library.resume();
    expect(library.canResolve, true);
    expect(transport.operations, contains('/volume/attach'));
  });
  test(
    'resolves stable IDs through Cadence without constructing a mount path',
    () async {
      final pending = library.resolve('library', 4);
      await transport.resolving.future;
      expect(transport.body, {
        'libraryUuid': 'library',
        'itemId': 4,
        'volumeId': 'volume',
        'generation': 'mount1',
      });
      transport.complete();
      expect((await pending).path, '/proc/123/fd/9/Music/song.mp3');
    },
  );
  test('eject blocks outstanding and new resolutions', () async {
    final pending = library.resolve('library', 4);
    await transport.resolving.future;
    library.blockPlayback();
    final rejected = expectLater(pending, throwsStateError);
    transport.complete();
    await rejected;
    await expectLater(library.resolve('library', 4), throwsStateError);
  });
  test('a card event invalidates in-flight path resolution', () async {
    final pending = library.resolve('library', 4);
    await transport.resolving.future;
    transport.stream.add({'type': 'volume-state-changed'});
    final rejected = expectLater(pending, throwsStateError);
    transport.complete();
    await rejected;
    expect(library.canResolve, false);
  });
  test('mismatched attachment generations are rejected', () async {
    final pending = library.resolve('library', 4);
    await transport.resolving.future;
    final rejected = expectLater(pending, throwsStateError);
    transport.complete(generation: 'mount2');
    await rejected;
  });
}
