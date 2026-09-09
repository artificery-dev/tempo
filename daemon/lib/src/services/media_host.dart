import 'dart:async';
import 'dart:io';

import 'package:cadence_media/cadence_media.dart';
import 'media_scheduler.dart';

/// Owns the library database and scanner independently of the Flutter lifetime.
final class MediaHost {
  MediaHost(this._client);

  static Future<MediaHost> open(String databasePath) async {
    await File(databasePath).parent.create(recursive: true);
    return MediaHost(
      await MediaServer.spawn(
        databasePath: databasePath,
        policy: const ScanPolicy(
          identity: IdentityHash.sampled,
          hashSpan: 256 * 1024,
          artwork: ArtworkPolicy.deferred,
        ),
        lowPriority: true,
      ),
    );
  }

  final MediaClient _client;
  MediaScheduler? scheduler;
  Future<void> schedule({
    required String home,
    Map<String, Object?> settings = const {},
  }) async {
    final next = MediaScheduler(_client, home: home)..configure(settings);
    scheduler = next;
    await next.start();
  }

  bool _closed = false;
  final _pending = <Future<Map<String, Object?>>>{};

  Future<Map<String, Object?>> handle(Map<String, Object?> envelope) {
    if (_closed) throw StateError('Media service is closed.');
    final request = ServiceRequest.fromMap(envelope);
    if (request.path == '/scheduler') {
      final owner = scheduler;
      if (owner == null) {
        return Future.value(
          ServiceResponse(id: request.id, status: 503).toMap(),
        );
      }
      if (request.method != ServiceMethod.get &&
          request.method != ServiceMethod.post) {
        return Future.value(
          ServiceResponse(id: request.id, status: 405).toMap(),
        );
      }
      if (request.method == ServiceMethod.post) unawaited(owner.scan());
      return Future.value(
        ServiceResponse(
          id: request.id,
          status: 200,
          body: owner.status,
        ).toMap(),
      );
    }
    final result = _client
        .send(request.method, request.path, request.body)
        .then((response) => {...response.toMap(), 'id': request.id});
    _pending.add(result);
    unawaited(
      result.then<void>(
        (_) => _pending.remove(result),
        onError: (Object _, StackTrace _) {
          _pending.remove(result);
        },
      ),
    );
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await scheduler?.close();
    await Future.wait(
      _pending.map(
        (f) => f.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    await _client.close();
  }
}
