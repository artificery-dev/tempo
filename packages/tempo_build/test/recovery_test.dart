import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:tempo_build/src/recovery.dart';
import 'package:tempo_build/src/process.dart';
import 'package:test/test.dart';

void main() {
  test(
    'packaging elsewhere needs images a Linux build already produced',
    () async {
      final root = Directory.systemTemp.createTempSync('tempo-recovery-host-');
      addTearDown(() => root.deleteSync(recursive: true));
      expect(recoveryImagesPresent(root.path), isFalse);
      for (final name in RecoveryBuildCache.outputs) {
        File('${root.path}/build/recovery/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('image');
      }
      expect(recoveryImagesPresent(root.path), isTrue);
      File('${root.path}/build/recovery/preloader.bin').deleteSync();
      expect(recoveryImagesPresent(root.path), isFalse);
    },
  );

  test(
    'recovery cache rebuilds missing, changed and corrupted artifacts',
    () async {
      final root = Directory.systemTemp.createTempSync('tempo-recovery-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final cache = RecoveryBuildCache(root.path);
      var builds = 0;
      Future<void> build() async {
        builds++;
        for (final name in RecoveryBuildCache.outputs) {
          File('${root.path}/build/recovery/$name')
            ..createSync(recursive: true)
            ..writeAsStringSync('build $builds');
        }
      }

      expect(await cache.ensure({'kernel': 'a'}, build), isTrue);
      expect(await cache.ensure({'kernel': 'a'}, build), isFalse);
      expect(await cache.ensure({'kernel': 'b'}, build), isTrue);
      File('${root.path}/build/recovery/payload.bin').deleteSync();
      expect(await cache.ensure({'kernel': 'b'}, build), isTrue);
      File(
        '${root.path}/build/recovery/ramboot-DA.bin',
      ).writeAsStringSync('corrupt');
      expect(await cache.ensure({'kernel': 'b'}, build), isTrue);
      cache.stamp.writeAsStringSync('{');
      expect(await cache.ensure({'kernel': 'b'}, build), isTrue);
      await expectLater(
        cache.ensure({'kernel': 'c'}, () async {
          throw StateError('failed');
        }),
        throwsStateError,
      );
      expect(cache.stamp.existsSync(), isFalse);
      expect(await cache.ensure({'kernel': 'b'}, build), isTrue);
      expect(await cache.ensure({'kernel': 'b'}, build), isFalse);
    },
  );

  test(
    'recovery input hashes detect content changes despite preserved times',
    () async {
      final root = Directory.systemTemp.createTempSync('tempo-recovery-input-');
      addTearDown(() => root.deleteSync(recursive: true));
      final input = File('${root.path}/input')..writeAsStringSync('old');
      final modified = input.lastModifiedSync();
      final cache = RecoveryBuildCache(root.path);
      final before = await cache.hashes(['input']);
      input
        ..writeAsStringSync('new')
        ..setLastModifiedSync(modified);
      expect(await cache.hashes(['input']), isNot(before));
    },
  );

  test(
    'recovery has LK addresses, recovery wrapper and appended device tree',
    () {
      final kernel = Uint8List(4096);
      ByteData.sublistView(kernel).setUint32(0x24, 0x016f2818, Endian.little);
      final tree = Uint8List(40);
      ByteData.sublistView(tree).setUint32(0, 0xd00dfeed, Endian.big);
      final image = recoveryImage(kernel, tree);
      final header = ByteData.sublistView(image);
      expect(ascii.decode(image.sublist(0, 8)), 'ANDROID!');
      expect(header.getUint32(12, Endian.little), 0x10008000);
      expect(header.getUint32(20, Endian.little), 0x11000000);
      expect(header.getUint32(36, Endian.little), 2048);
      expect(image.sublist(2048 + 512, 2048 + 512 + kernel.length), kernel);
      expect(
        image.sublist(
          2048 + 512 + kernel.length,
          2048 + 512 + kernel.length + tree.length,
        ),
        tree,
      );
      final ramdiskOffset =
          2048 + ((512 + kernel.length + tree.length + 2047) ~/ 2048) * 2048;
      expect(
        ascii.decode(image.sublist(ramdiskOffset + 8, ramdiskOffset + 16)),
        'RECOVERY',
      );
      expect(
        image.sublist(ramdiskOffset + 512).every((byte) => byte == 0),
        isTrue,
      );
      expect(
        () => recoveryImage(Uint8List(100), tree),
        throwsA(isA<BuildFailure>()),
      );
      expect(
        () => recoveryImage(kernel, Uint8List(40)),
        throwsA(isA<BuildFailure>()),
      );
      final oversized = Uint8List(0x1000000);
      ByteData.sublistView(
        oversized,
      ).setUint32(0x24, 0x016f2818, Endian.little);
      expect(
        () => recoveryImage(oversized, tree),
        throwsA(isA<BuildFailure>()),
      );
    },
  );
}
