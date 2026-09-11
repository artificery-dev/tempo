import 'dart:convert';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:daemon_client/daemon_client.dart'
    show DeviceClient, DeviceSnapshot, StorageClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo/src/daemon_card_maintenance.dart';

class Transport implements MediaTransport {
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async => {
    'id': 'library',
    'generation': '1',
    'state': 'attached',
    'storageKind': 'local',
    'readyToUnmount': false,
    'rootAvailabilityReady': true,
    'quiescentRootIds': [],
    'quiescentMountPaths': [],
    'activity': {},
  };
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<List<int>?> artwork(int id) async => null;
  @override
  Future<void> close() async {}
}

void main() {
  test(
    'failed eject keeps playback blocked until explicit host resume',
    () async {
      final calls = <String>[];
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        calls.add('http:${body['action']}');
        expect(body['cardId'], 'card');
        expect(body['mountId'], '40');
        request.response.headers.contentType = ContentType.json;
        if (body['action'] == 'eject') {
          request.response.statusCode = 409;
          request.response.write(
            jsonEncode({
              'error': {'message': 'Card is busy'},
            }),
          );
        } else {
          request.response.write(jsonEncode({'state': 'resumed'}));
        }
        await request.response.close();
      });
      final base = Uri.parse('http://127.0.0.1:${http.port}');
      final device = DeviceClient(baseUri: base, token: 'token')
        ..snapshot = const DeviceSnapshot(
          cardPath: '/mnt/sd',
          cardMountId: '40',
          cardSourceId: 'card',
        );
      final cadence = CadenceLibrary(CadenceClient(Transport()));
      await cadence.refresh();
      final controller = DaemonCardMaintenance(
        client: StorageClient(baseUri: base, token: 'token'),
        cadence: cadence,
        device: device,
        stopPlayback: () async {
          expect(cadence.canResolve, isFalse);
          calls.add('stop');
        },
      );
      try {
        await controller.eject();
        expect(calls, ['stop', 'http:eject']);
        expect(controller.value.phase, CardMaintenancePhase.failed);
        expect(cadence.canResolve, isFalse);
        await controller.resume();
        expect(calls, ['stop', 'http:eject', 'stop', 'http:resume']);
        expect(controller.value.phase, CardMaintenancePhase.idle);
        expect(cadence.canResolve, isTrue);
      } finally {
        controller.dispose();
        await cadence.close();
        await device.close();
        await http.close(force: true);
      }
    },
  );
}
