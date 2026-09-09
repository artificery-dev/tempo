import 'dart:typed_data';
import 'package:file/memory.dart';
import 'package:tempo_build/src/tempo_layout.dart';
import 'package:test/test.dart';

void main() {
  test('MBR exposes exactly the existing rootfs as Linux partition one', () {
    final bytes = TempoLayout.partitionTable();
    final data = ByteData.sublistView(bytes);
    expect(bytes.length, 512);
    expect(bytes.sublist(510), [0x55, 0xaa]);
    expect(bytes[450], 0x83);
    expect(data.getUint32(454, Endian.little) * 512, TempoLayout.rootfsOffset);
    expect(data.getUint32(458, Endian.little) * 512, TempoLayout.rootfsSize);
    expect(bytes.sublist(462, 510), everyElement(0));
    expect(
      TempoLayout.rootfsOffset + TempoLayout.rootfsSize,
      TempoLayout.userSize,
    );
  });
  test(
    'native package has one rootfs and publishes partition table last',
    () async {
      final dir = MemoryFileSystem().directory('/images')..createSync();
      for (final name in [
        'boot.img',
        'recovery.img',
        'logo.img',
        'rootfs.ext4',
      ]) {
        dir.childFile(name).writeAsBytesSync(List.filled(512, 1));
      }
      final manifest = await tempoInstallerManifest(
        directory: dir,
        version: '0.9.0',
        commit: 'test',
        icon: '',
      );
      final images = manifest['images'] as List;
      final writes = images
          .map((image) => (image['writes'] as List).single as Map)
          .toList();
      expect(writes.map((w) => w['name']), [
        'boot',
        'recovery',
        'splash',
        'rootfs',
        'partition-table',
      ]);
      expect(writes.map((w) => w['target_offset']), [
        0x2900000,
        0x3900000,
        0x4f80000,
        0x5180000,
        0,
      ]);
      dir.childFile('logo.img').writeAsBytesSync(List.filled(0x200001, 0));
      await expectLater(
        tempoInstallerManifest(
          directory: dir,
          version: '0.9.0',
          commit: 'test',
          icon: '',
        ),
        throwsFormatException,
      );
    },
  );
}
