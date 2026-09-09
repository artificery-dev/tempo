import 'dart:io' show stdout;
import 'package:file/local.dart';
import 'dart:typed_data';

import 'context.dart';
import 'kernel.dart';
import 'process.dart';

/// LK uses the same Android/MTK container as BOOTIMG. Recovery's initramfs is
/// built into its kernel: never attach the normal automatic-install ramdisk.
Uint8List recoveryImage(List<int> kernel, List<int> deviceTree) {
  if (kernel.length < 0x30 ||
      ByteData.sublistView(
            Uint8List.fromList(kernel),
          ).getUint32(0x24, Endian.little) !=
          0x016f2818) {
    throw BuildFailure('Recovery kernel is not an ARM zImage');
  }
  if (deviceTree.length < 40 ||
      ByteData.sublistView(
            Uint8List.fromList(deviceTree),
          ).getUint32(0, Endian.big) !=
          0xd00dfeed) {
    throw BuildFailure('Recovery device tree is invalid');
  }
  // Retain the LK-compatible placeholder ramdisk used by our normal boot image
  // when no external initramfs is supplied. Linux uses its built-in /init.
  return bootImage(
    mtkHeader([...kernel, ...deviceTree], 'KERNEL'),
    mtkHeader(Uint8List(9 * 2048), 'RECOVERY'),
    maxSize: 0x1000000,
  );
}

Future<void> buildRecovery(Repository repo, CommandRunner runner) async {
  await Toolchain(repo, runner).run(['sh', 'platform/recovery/build.sh']);
  const fs = LocalFileSystem();
  final output = repo.path('build/recovery');
  final image = recoveryImage(
    fs.file('$output/kernel/arch/arm/boot/zImage').readAsBytesSync(),
    fs
        .file(
          '$output/kernel/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dtb',
        )
        .readAsBytesSync(),
  );
  final temporary = fs.file('$output/recovery.img.tmp');
  temporary.writeAsBytesSync(image, flush: true);
  temporary.renameSync('$output/recovery.img');
  stdout.writeln(
    'Packaged LK recovery image: ${image.length} / 16777216 bytes',
  );
}
