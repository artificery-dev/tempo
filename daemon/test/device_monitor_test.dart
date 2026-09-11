import 'dart:io';

import 'package:daemon_client/daemon_client.dart';
import 'package:tempod/src/services/device_monitor.dart';
import 'package:tempod/tempod.dart';
import 'package:test/test.dart';

void main() {
  test(
    'kernel card activity distinguishes idle, recent I/O, active I/O and unknown',
    () async {
      final dir = await Directory.systemTemp.createTemp('card-activity-');
      final mounts = File('${dir.path}/mounts')
        ..writeAsStringSync('/dev/mmcblk1p1 /mnt/sd exfat rw 0 0\n');
      final info = File('${dir.path}/mountinfo')
        ..writeAsStringSync(
          '40 1 179:9 / /mnt/sd rw - exfat /dev/mmcblk1p1 rw\n',
        );
      final stats = File('${dir.path}/stat')
        ..writeAsStringSync('10 0 100 1 20 0 200 1 0 1 1');
      final monitor = DeviceMonitor(
        native: _BatteryNative(),
        mountsPath: mounts.path,
        mountInfoPath: info.path,
        cardStatsPath: stats.path,
        cardIdentityPath: '${dir.path}/missing-cid',
      );
      try {
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isNull);
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isFalse);
        stats.writeAsStringSync('11 0 108 2 20 0 200 1 0 2 2');
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isTrue);
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isFalse);
        stats.writeAsStringSync('11 0 108 2 20 0 200 1 1 2 2');
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isTrue);
        stats.writeAsStringSync('unavailable');
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isNull);
        stats.writeAsStringSync('11 0 108 2 20 0 200 1 0 2 2');
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isNull);
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isFalse);
        info.writeAsStringSync(
          '41 1 179:9 / /mnt/sd rw - exfat /dev/mmcblk1p1 rw\n',
        );
        await monitor.refresh();
        expect(monitor.snapshot.cardIoBusy, isNull);
      } finally {
        await monitor.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'daemon serves native battery and decoded card mounts; loss becomes unknown',
    () async {
      final dir = await Directory.systemTemp.createTemp('device-monitor-');
      final mounts = File('${dir.path}/mounts');
      await mounts.writeAsString(
        '/dev/mmcblk10p1 /wrong ext4 rw 0 0\n/dev/mmcblk1p1 /media/SD\\040Card ext4 rw 0 0\n',
      );
      final mountInfo = File('${dir.path}/mountinfo');
      await mountInfo.writeAsString(
        r'41 22 179:9 / /media/SD\040Card rw - exfat /dev/mmcblk1p1 rw'
        '\n',
      );
      final cid = File('${dir.path}/cid');
      const physicalId = '035344534331364780b97f819a014a11';
      await cid.writeAsString(physicalId);
      final native = _BatteryNative();
      final monitor = DeviceMonitor(
        native: native,
        mountsPath: mounts.path,
        mountInfoPath: mountInfo.path,
        cardIdentityPath: cid.path,
      );
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
        expect(client.snapshot.cardMountId, '41');
        expect(client.snapshot.cardSourceId, physicalId);
        await mountInfo.writeAsString(
          r'63 22 179:9 / /media/SD\040Card rw - exfat /dev/mmcblk1p1 rw'
          '\n',
        );
        await monitor.refresh();
        await client.refresh();
        expect(client.snapshot.cardMountId, '63');
        expect(client.snapshot.cardSourceId, physicalId);
        await cid.writeAsString('/media/SD Card');
        await monitor.refresh();
        expect(monitor.snapshot.cardSourceId, isNull);
        await mountInfo.delete();
        await monitor.refresh();
        expect(monitor.snapshot.cardMountId, isNull);
        expect(monitor.snapshot.cardPath, '/media/SD Card');
        native.fail = true;
        await mounts.writeAsString('');
        await monitor.refresh();
        await client.refresh();
        expect(client.snapshot.batteryPercent, isNull);
        expect(client.snapshot.cardPath, isNull);
        expect(client.snapshot.cardMountId, isNull);
        expect(client.snapshot.cardSourceId, isNull);
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
