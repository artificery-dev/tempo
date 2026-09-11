import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
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

/// Content provenance avoids timestamps surviving a checkout or copied build.
class RecoveryBuildCache {
  RecoveryBuildCache(this.root);
  final String root;
  static const outputs = [
    'ramboot-DA.bin',
    'payload.bin',
    'preloader.bin',
    'recovery.img',
  ];
  File get stamp => File(p.join(root, 'build/recovery/build-state.json'));

  Future<Map<String, String>> hashes(Iterable<String> paths) async {
    final result = <String, String>{};
    for (final path in paths) {
      final file = File(p.join(root, path));
      result[path] = file.existsSync()
          ? (await sha256.bind(file.openRead()).first).toString()
          : 'missing';
    }
    return result;
  }

  Future<bool> ensure(
    Map<String, Object?> inputs,
    Future<void> Function() build,
  ) async {
    final paths = outputs.map((name) => 'build/recovery/$name').toList();
    final before = await hashes(paths);
    if (!before.containsValue('missing') && stamp.existsSync()) {
      try {
        final previous = jsonDecode(stamp.readAsStringSync()) as Map;
        if (jsonEncode(previous['inputs']) == jsonEncode(inputs) &&
            jsonEncode(previous['outputs']) == jsonEncode(before))
          return false;
      } on FormatException {
        // An interrupted or obsolete stamp is a cache miss.
      } on TypeError {
        // Older formats cannot establish freshness.
      }
    }
    if (stamp.existsSync()) stamp.deleteSync();
    await build();
    final after = await hashes(paths);
    if (after.containsValue('missing')) {
      throw BuildFailure('Recovery build did not produce all required images');
    }
    stamp.parent.createSync(recursive: true);
    final temporary = File('${stamp.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode({'inputs': inputs, 'outputs': after}),
    );
    temporary.renameSync(stamp.path);
    return true;
  }
}

/// Whether the images the Toolbox packages are all present.
bool recoveryImagesPresent(String root) => RecoveryBuildCache.outputs.every(
  (name) => File(p.join(root, 'build/recovery', name)).existsSync(),
);

Future<void> ensureRecovery(Repository repo, CommandRunner runner) async {
  // Recovery is cross-built in the Linux toolchain container, and its inputs
  // include the kernel submodule, which cannot even be checked out on a
  // case-insensitive filesystem. Elsewhere the images have to arrive ready
  // made, from a Linux build of this checkout or from CI's artifact.
  if (!Platform.isLinux) {
    if (recoveryImagesPresent(repo.root)) return;
    throw BuildFailure(
      'Recovery is built on Linux. Copy build/recovery from a Linux build of '
      'this checkout, or take CI\'s recovery images, before packaging here.',
    );
  }
  final kernel = KernelSource(repo, runner);
  final state = await kernel.sourceState();
  if (state.dirty) {
    throw BuildFailure(
      'Kernel source has uncommitted changes. Commit them in '
      'the kernel fork before building Recovery; no source was changed.',
    );
  }
  final paths = <String>[
    'platform/kernel/config/y2.config',
    'platform/rootfs/initramfs/busybox/busybox-armv7l',
    'platform/firmware/stock/rockbox-MTK_AllInOne_DA.bin',
    'platform/firmware/stock/preloader_eastaeon82_wet_kk.bin',
    'packages/tempo_build/lib/src/recovery.dart',
    'packages/tempo_build/lib/src/kernel.dart',
    'packages/tempo_build/lib/src/context.dart',
  ];
  for (final directory in ['platform/recovery', 'assets/tempo/svg']) {
    for (final entry in Directory(
      repo.path(directory),
    ).listSync(recursive: true)) {
      if (entry is File) paths.add(p.relative(entry.path, from: repo.root));
    }
  }
  paths.sort();
  final cache = RecoveryBuildCache(repo.root);
  await cache.ensure(
    {
      'version': 1,
      'kernel': (await kernel.git([
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim(),
      // The compilers come from the image, so a new image is a new build.
      'toolchain': Toolchain(repo, runner).image,
      'files': await cache.hashes(paths),
    },
    () async {
      stdout.writeln('Building missing or outdated Tempo Recovery…');
      await buildRecovery(repo, runner);
    },
  );
}

Future<void> buildRecovery(Repository repo, CommandRunner runner) async {
  final stamp = RecoveryBuildCache(repo.root).stamp;
  if (stamp.existsSync()) stamp.deleteSync();
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
