import 'dart:convert';
import 'dart:typed_data';
import 'package:tempo_build/src/recovery.dart';
import 'package:tempo_build/src/process.dart';
import 'package:test/test.dart';

void main() {
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
