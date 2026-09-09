import 'dart:async';
import 'package:cadence_media/cadence_media.dart';
import 'package:test/test.dart';
import 'package:tempod/src/services/media_scheduler.dart';

void main() {
  test(
    'shutdown cancels a running scan instead of awaiting its full library',
    () async {
      final polling = Completer<void>();
      var cancelled = false;
      final client = MediaClient((map) async {
        final request = ServiceRequest.fromMap(map);
        final body = switch ((request.method, request.path)) {
          (ServiceMethod.get, '/libraries/1/roots') => <String, Object?>{
            'roots': [],
          },
          (ServiceMethod.post, '/libraries/1/scan') => <String, Object?>{},
          (ServiceMethod.delete, '/libraries/1/scan') => <String, Object?>{
            'cancelled': cancelled = true,
          },
          (ServiceMethod.get, '/libraries/1/scan') => <String, Object?>{
            'state': 'extracting',
          },
          _ => throw StateError('Unexpected request ${request.path}'),
        };
        if (request.method == ServiceMethod.get &&
            request.path.endsWith('/scan') &&
            !polling.isCompleted) {
          polling.complete();
        }
        return ServiceResponse(id: request.id, status: 200, body: body).toMap();
      });
      final scheduler = MediaScheduler(
        client,
        home: '/nonexistent-tempo-shutdown',
        pollPeriod: const Duration(milliseconds: 5),
      );
      scheduler.ids['music'] = 1;
      final scan = scheduler.scan();
      await polling.future.timeout(const Duration(seconds: 1));
      await scheduler.close().timeout(const Duration(seconds: 1));
      await scan;
      expect(cancelled, isTrue);
      expect(scheduler.status['running'], isFalse);
    },
  );
}
