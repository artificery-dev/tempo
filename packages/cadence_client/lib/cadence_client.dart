import 'dart:async';
import 'src/volume.dart';
export 'src/volume.dart';

/// Version 1 transports exchange JSON values; artwork has a separate byte path.
abstract interface class MediaTransport {
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]);
  Future<List<int>?> artwork(int fileId);
  Stream<Map<String, Object?>> get events;
  Future<void> close();
}

class MediaError implements Exception {
  MediaError(this.code, this.message, this.status);
  final String code, message;
  final int status;
  @override
  String toString() => '$code ($status): $message';
}

/// Wire-only client: no database rows or extraction dependencies.
class CadenceClient {
  CadenceClient(this.transport);
  final MediaTransport transport;
  Future<Map<String, Object?>> call(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) => transport.request(method, path, body);
  Future<VolumeStatus> setRootAvailability({
    required String expectedId,
    required String expectedGeneration,
    required List<RootAvailability> roots,
  }) async => VolumeStatus.fromJson(
    await call('post', '/volume/roots', {
      'expectedId': expectedId,
      'expectedGeneration': expectedGeneration,
      'roots': roots.map((r) => r.toJson()).toList(),
    }),
  );
  Future<VolumeStatus> volumeStatus() async =>
      VolumeStatus.fromJson(await volume());
  Future<MediaLocation> resolveMedia({
    required String libraryUuid,
    required int itemId,
    required String volumeId,
    required String generation,
  }) async => MediaLocation.fromJson(
    await call('post', '/media/resolve', {
      'libraryUuid': libraryUuid,
      'itemId': itemId,
      'volumeId': volumeId,
      'generation': generation,
    }),
  );
  Future<Map<String, Object?>> volume() => call('get', '/volume');
  Future<Map<String, Object?>> attachVolume({
    String? expectedId,
    String? expectedGeneration,
  }) => call('post', '/volume/attach', {
    if (expectedId != null) 'expectedId': expectedId,
    if (expectedGeneration != null) 'expectedGeneration': expectedGeneration,
  });
  Future<Map<String, Object?>> ejectVolume({
    String? expectedId,
    String? expectedGeneration,
  }) => call('post', '/volume/eject', {
    if (expectedId != null) 'expectedId': expectedId,
    if (expectedGeneration != null) 'expectedGeneration': expectedGeneration,
  });
  Future<Map<String, Object?>> snapshot() => call('get', '/snapshot');
  Future<int> createLibrary(String name, String type) async =>
      (await call('post', '/libraries', {'name': name, 'type': type}))['id']
          as int;
  Future<int> addRoot(int library, String path) async =>
      (await call('post', '/libraries/$library/roots', {'path': path}))['id']
          as int;
  Future<Map<String, Object?>> scan(int library) =>
      call('post', '/libraries/$library/scan');
  Future<Map<String, Object?>> job(String id) => call('get', '/jobs/$id');
  Future<void> cancel(String id) => call('delete', '/jobs/$id');
  Future<List<Object?>> items(int library) async =>
      (await call('get', '/libraries/$library/items'))['items'] as List;
  Future<List<int>?> artwork(int file) => transport.artwork(file);
  Stream<Map<String, Object?>> get events => transport.events;
  Future<void> close() => transport.close();
}
