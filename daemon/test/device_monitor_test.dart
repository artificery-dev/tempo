import 'dart:io';

import 'package:daemon_client/daemon_client.dart';
import 'package:tempod/src/services/device_monitor.dart';
import 'package:tempod/tempod.dart';
import 'package:test/test.dart';

void main() {
  test(
    'daemon serves native battery and decoded card mounts; loss becomes unknown',
    () async {
      final dir = await Directory.systemTemp.createTemp('device-monitor-');
      final mounts = File('${dir.path}/mounts');
      await mounts.writeAsString(
        '/dev/mmcblk10p1 /wrong ext4 rw 0 0\n/dev/mmcblk1p1 /media/SD\\040Card ext4 rw 0 0\n',
      );
      final native = _BatteryNative();
      final monitor = DeviceMonitor(native: native, mountsPath: mounts.path);
      final server = PlayerServer(
        player: DemoPlayer(),
        token: 'device-test',
        deviceMonitor: monitor,
      );
      await server.start();
      final client = DeviceClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'device-test',
      );
      try {
        await monitor.refresh();
        await client.refresh();
        expect(client.snapshot.batteryPercent, 63);
        expect(client.snapshot.charging, isTrue);
        expect(client.snapshot.cardPath, '/media/SD Card');
        native.fail = true;
        await mounts.writeAsString('');
        await monitor.refresh();
        await client.refresh();
        expect(client.snapshot.batteryPercent, isNull);
        expect(client.snapshot.cardPath, isNull);
        await server.close();
        await client.refresh();
        expect(client.snapshot.toJson(), const DeviceSnapshot().toJson());
      } finally {
        await client.close();
        await server.close();
        await (server.player as DemoPlayer).close();
        await monitor.close();
        await dir.delete(recursive: true);
      }
    },
  );
}

final class _BatteryNative extends Tempod {
  bool fail = false;
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> request) async {
    expect(request, {'op': 'battery'});
    if (fail) throw const SocketException('Offline');
    return {'capacity': 63, 'charging': true};
  }
}
