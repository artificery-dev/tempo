import 'package:test/test.dart';
import '../../../platform/rootfs/tool/sd_formatter.dart';

void main() {
  test(
    'original card identity is required before any formatter action',
    () async {
      final calls = <String>[];
      final formatter = SdFormatter(
        read: (path) async => path.endsWith('/type') ? 'SD' : 'new-card',
        command: (exe, _, _) async {
          calls.add(exe);
        },
      );
      await expectLater(
        formatter.format(expectedCardId: 'original-card'),
        throwsStateError,
      );
      expect(calls, isEmpty);
    },
  );
  test(
    'formats only verified SD, unmounts normally and masks automount',
    () async {
      var mounted = true;
      final calls = <String>[];
      final formatter = SdFormatter(
        read: (path) async => switch (path) {
          '/sys/class/block/mmcblk1/device/type' => 'SD',
          '/sys/class/block/mmcblk1/device/cid' => 'card1',
          '/sys/class/block/mmcblk1/size' => '31116288',
          '/proc/mounts' => mounted ? '/dev/mmcblk1p1 /mnt/sd vfat rw 0 0' : '',
          _ => throw StateError(path),
        },
        command: (exe, args, input) async {
          calls.add('$exe ${args.join(' ')}');
          if (exe == '/bin/umount') mounted = false;
          if (exe == '/usr/sbin/sfdisk')
            expect(input, 'label: dos\nstart=2048, type=7\n');
        },
      );
      await formatter.format();
      expect(calls.first, '/bin/umount /mnt/sd');
      expect(
        calls.indexWhere((v) => v.contains('mask --runtime')),
        lessThan(calls.indexWhere((v) => v.contains('sfdisk'))),
      );
      expect(calls, contains('/usr/sbin/mkfs.exfat -L TEMPO /dev/mmcblk1p1'));
      expect(calls.last, '/usr/bin/systemctl start tempo-sdmount.service');
      expect(
        calls.any((v) => v.contains('mmcblk0') || v.contains('umount -l')),
        false,
      );
    },
  );
  test('rejects eMMC identification before any mutation', () async {
    var called = false;
    await expectLater(
      SdFormatter(
        read: (_) async => 'MMC',
        command: (_, _, _) async {
          called = true;
        },
      ).format(),
      throwsStateError,
    );
    expect(called, false);
  });
  test('busy unmount aborts before any formatting or lazy unit stop', () async {
    final calls = <String>[];
    await expectLater(
      SdFormatter(
        read: (path) async => switch (path) {
          '/sys/class/block/mmcblk1/device/type' => 'SD',
          '/sys/class/block/mmcblk1/device/cid' => 'card1',
          '/sys/class/block/mmcblk1/size' => '31116288',
          _ => '/dev/mmcblk1p1 /mnt/sd exfat rw 0 0',
        },
        command: (exe, _, _) async {
          calls.add(exe);
          throw StateError('busy');
        },
      ).format(),
      throwsStateError,
    );
    expect(calls, ['/bin/umount']);
  });
}
