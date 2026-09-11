import 'package:test/test.dart';
import '../../../platform/rootfs/tool/sd_ejector.dart';

void main() {
  var mounts = '';
  var type = 'SD';
  var mountId = '40';
  var replaceDuringSync = false;
  String? failure;
  final calls = <String>[];
  late SdEjector ejector;
  setUp(() {
    mounts = '/dev/mmcblk1p1 /mnt/sd exfat rw,sync 0 0';
    type = 'SD';
    mountId = '40';
    replaceDuringSync = false;
    failure = null;
    calls.clear();
    ejector = SdEjector(
      read: (path) async => switch (path) {
        '/proc/mounts' => mounts,
        '/proc/self/mountinfo' =>
          '$mountId 1 179:9 / /mnt/sd rw - exfat /dev/mmcblk1p1 rw',
        _ => type,
      },
      command: (exe, args, _) async {
        calls.add('$exe ${args.join(' ')}');
        if (exe == '/bin/sync' && replaceDuringSync) mountId = '41';
        if (exe == failure) throw StateError('I/O or busy error');
      },
    );
  });
  test('flushes and normally unmounts before stopping automount', () async {
    await ejector.eject();
    expect(calls, [
      '/bin/sync -f /mnt/sd',
      '/bin/umount /mnt/sd',
      '/usr/bin/systemctl stop tempo-sdmount.service',
    ]);
  });
  test('busy unmount never falls back to lazy unit stop', () async {
    failure = '/bin/umount';
    await expectLater(ejector.eject(), throwsStateError);
    expect(calls.length, 2);
    expect(calls.last, '/bin/umount /mnt/sd');
  });
  test('flush errors leave mount and service intact', () async {
    failure = '/bin/sync';
    await expectLater(ejector.eject(), throwsStateError);
    expect(calls, ['/bin/sync -f /mnt/sd']);
  });
  test('refuses eMMC and unexpected mount targets', () async {
    type = 'MMC';
    await expectLater(ejector.eject(), throwsStateError);
    type = 'SD';
    mounts = '/dev/mmcblk0p1 /mnt/sd ext4 rw 0 0';
    await expectLater(ejector.eject(), throwsStateError);
    mounts = '/dev/mmcblk1p2 /elsewhere exfat rw 0 0';
    await expectLater(ejector.eject(), throwsStateError);
    expect(calls, isEmpty);
  });
  test('already unmounted retry is harmless', () async {
    mounts = '';
    await ejector.eject();
    expect(calls, isEmpty);
  });
  test('mount identity is checked again after flushing', () async {
    replaceDuringSync = true;
    await expectLater(ejector.eject(expectedMountId: '40'), throwsStateError);
    expect(calls, ['/bin/sync -f /mnt/sd']);
  });
  test('stale mount identity cannot flush or unmount another card', () async {
    await expectLater(ejector.eject(expectedMountId: '39'), throwsStateError);
    expect(calls, isEmpty);
  });
}
