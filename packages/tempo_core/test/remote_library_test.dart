import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/src/services/library.dart';

void main() {
  test(
    'remote scan survives UI disposal and reconnect reads new shelves',
    () async {
      var revision = 0, running = false, count = 0;
      final mutations = <String>[];
      Future<Map<String, Object?>> send(Map<String, Object?> request) async {
        final path = request['path'], method = request['method'];
        Map<String, Object?> body;
        if (method != 'get') mutations.add('$method $path');
        if (path == '/libraries') {
          body = {
            'libraries': [
              {
                'id': 1,
                'name': 'Music',
                'type': 'music',
                'createdAt': '2026-01-01T00:00:00Z',
              },
            ],
          };
        } else if (path == '/libraries/1/tracks') {
          body = {
            'tracks': [
              for (var i = 0; i < count; i++)
                {
                  'id': i + 1,
                  'fileId': i + 1,
                  'path': '/card/Music/$i.wav',
                  'title': 'Track $i',
                },
            ],
          };
        } else if (path == '/scheduler') {
          if (method == 'post') running = true;
          body = {'epoch': 'test', 'revision': revision, 'running': running};
        } else {
          throw StateError('Unexpected UI operation: $request');
        }
        return {'id': request['id'], 'status': 200, 'body': body};
      }

      MediaLibrary open() => MediaLibrary.open(
        databasePath: null,
        transport: send,
        daemonScheduled: true,
        roots: () => ['/card/Music'],
        autoScan: Duration.zero,
        recheck: Duration.zero,
      );
      final first = open();
      await first.libraryId;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(mutations, isEmpty);
      final manual = first.scan();
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!running) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the scan never reached the daemon');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(running, true);
      await first.dispose();
      await manual;
      expect(running, true);
      count = 2;
      revision++;
      running = false;
      final second = open();
      await second.libraryId;
      expect(second.tracks.value, hasLength(2));
      expect(mutations, ['post /scheduler']);
      await second.dispose();
    },
  );
}
