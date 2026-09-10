import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/src/services/cadence_library.dart';
import 'package:tempo_core/src/services/cadence_media_library.dart';

class _Transport implements MediaTransport {
  final stream = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final mutations = <String>[];
  String generation = 'one';
  int items = 1;
  bool scanRunning = false;
  bool unavailable = false;
  Map<String, Object?> get volume => {
    'id': 'store',
    'generation': generation,
    'state': 'attached',
    'storageKind': 'portable',
    'resolvedMediaRoot': '/mnt/sd',
    'pathStyle': 'volume-posix',
    'rootAvailabilityReady': true,
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
    if (unavailable) throw StateError('Card is unavailable');
    if (method != 'get') mutations.add(path);
    if (path == '/volume') return volume;
    if (path == '/libraries')
      return {
        'libraries': [
          {'id': 1, 'uuid': 'music', 'name': 'Music', 'type': 'music'},
        ],
      };
    if (path.endsWith('/roots'))
      return {
        'roots': [
          {'id': 1, 'path': '/Music'},
        ],
      };
    if (path.endsWith('/tracks'))
      return {
        'tracks': [
          for (var i = 0; i < items; i++)
            {
              'id': i + 1,
              'fileId': i + 10,
              'path': '/Music/song$i.flac',
              'title': 'Song $i',
            },
        ],
      };
    if (path.endsWith('/items'))
      return {
        'items': [
          for (var i = 0; i < items; i++)
            {
              'id': i + 1,
              'fileId': i + 10,
              'path': '/Music/song$i.flac',
              'kind': 'audio',
              'metadata': {
                'title': 'Song $i',
                'artist': 'Artist',
                'durationMs': 1000,
              },
            },
        ],
      };
    if (path.endsWith('/scan')) {
      if (method == 'post') scanRunning = true;
      return {
        'state': scanRunning ? 'walking' : 'idle',
        if (method == 'post') 'jobId': 'job',
      };
    }
    if (path == '/media/resolve')
      return {
        'libraryUuid': body!['libraryUuid'],
        'itemId': body['itemId'],
        'volumeId': 'store',
        'generation': generation,
        'path': '/proc/42/fd/7/Music/song.flac',
      };
    throw StateError('Unexpected $method $path');
  }

  @override
  Stream<Map<String, Object?>> get events => stream.stream;
  @override
  Future<List<int>?> artwork(int _) async => [1, 2, 3];
  @override
  Future<void> close() => stream.close();
}

void main() {
  late _Transport transport;
  late CadenceLibrary attachment;
  late CadenceMediaLibrary library;
  setUp(() async {
    transport = _Transport();
    attachment = CadenceLibrary(CadenceClient(transport));
    await attachment.connect();
    library = CadenceMediaLibrary(attachment);
    await library.ready;
  });
  tearDown(() async {
    await library.dispose();
    await attachment.close();
    await transport.close();
  });
  test(
    'reads shelves without creating libraries, roots, or automatic scans',
    () {
      expect(library.status.value.error, isNull);
      expect(library.tracks.value.single.title, 'Song 0');
      expect(transport.mutations, isEmpty);
    },
  );
  test('uses datastore and library IDs instead of the display path', () async {
    final track = library.tracks.value.single;
    expect(await library.resolvePath(track), '/proc/42/fd/7/Music/song.flac');
    expect(transport.mutations, ['/media/resolve']);
  });
  test(
    'missing media invalidates old paths and can reconnect without a new UI',
    () async {
      final original = library.tracks.value.single;
      transport.unavailable = true;
      await library.refresh();
      expect(library.status.value.error, isNotNull);
      expect(library.tracks.value, isEmpty);
      expect(attachment.canResolve, isFalse);
      await expectLater(library.resolvePath(original), throwsStateError);
      transport.unavailable = false;
      transport.generation = 'returned';
      await library.refresh();
      expect(library.status.value.error, isNull);
      expect(library.tracks.value.single.title, 'Song 0');
      await expectLater(library.resolvePath(original), throwsStateError);
    },
  );
  test(
    'old shelf references cannot resolve after a generation change',
    () async {
      final track = library.tracks.value.single;
      transport.generation = 'two';
      await expectLater(library.resolvePath(track), throwsStateError);
      expect(transport.mutations, isEmpty);
    },
  );
  test('folder settings stay relative to the declared media base', () {
    expect(library.locations!(), ['/mnt/sd']);
    expect(library.encodeFolderPath('/mnt/sd/Music'), '/Music');
    expect(
      () => library.encodeFolderPath('/home/tempo/Music'),
      throwsArgumentError,
    );
  });
  test('manual scan survives closing the UI client', () async {
    await library.scan();
    expect(transport.scanRunning, true);
    await library.dispose();
    expect(transport.scanRunning, true);
    expect(transport.mutations, ['/libraries/1/scan']);
  });
}
