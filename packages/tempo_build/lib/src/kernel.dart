import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';

Uint8List mtkHeader(List<int> payload, String name) {
  final encoded = ascii.encode(name);
  if (encoded.length > 32) throw ArgumentError('MTK name exceeds 32 bytes');
  final header = Uint8List(512 + payload.length)..fillRange(0, 512, 255);
  header.setRange(0, 4, [0x88, 0x16, 0x88, 0x58]);
  ByteData.sublistView(header).setUint32(4, payload.length, Endian.little);
  header.fillRange(8, 40, 0);
  header.setRange(8, 8 + encoded.length, encoded);
  header.setRange(512, header.length, payload);
  return header;
}

Uint8List bootImage(
  List<int> kernel,
  List<int> ramdisk, {
  int maxSize = 0x1000000,
}) {
  const page = 2048;
  int padded(int length) => (length + page - 1) ~/ page * page;
  final size = page + padded(kernel.length) + padded(ramdisk.length);
  if (size > maxSize)
    throw BuildFailure(
      'Boot image is $size bytes, ${size - maxSize} over the $maxSize-byte BOOTIMG partition',
    );
  final bytes = Uint8List(size);
  bytes.setRange(0, 8, ascii.encode('ANDROID!'));
  final header = ByteData.sublistView(bytes);
  final values = [
    kernel.length,
    0x10008000,
    ramdisk.length,
    0x11000000,
    0,
    0x10f00000,
    0x10000100,
    page,
  ];
  for (var index = 0; index < values.length; index++)
    header.setUint32(8 + index * 4, values[index], Endian.little);
  bytes.setRange(page, page + kernel.length, kernel);
  bytes.setRange(
    page + padded(kernel.length),
    page + padded(kernel.length) + ramdisk.length,
    ramdisk,
  );
  return bytes;
}

/// Hashes the tracked diff plus every untracked file, including file modes
/// and symlink targets. Builds require committed sources and preserve hand edits.
class KernelSource {
  KernelSource(this.repository, this.runner);
  final Repository repository;
  final CommandRunner runner;
  String get source => repository.path('platform/kernel/linux');
  File get state => File(repository.path('build/os/kernel/tempo-source.json'));
  Future<ProcessResult> git(List<String> args) =>
      runner.capture('git', args, workingDirectory: source);
  Future<({Map<String, Object> value, bool dirty})> sourceState() async {
    final names =
        (await git(['ls-files', '--others', '--exclude-standard', '-z'])).stdout
            .toString()
            .split('\u0000')
            .where((name) => name.isNotEmpty)
            .toList();
    final diff = await Process.run(
      'git',
      ['diff', 'HEAD', '--binary'],
      workingDirectory: source,
      stdoutEncoding: null,
    );
    if (diff.exitCode != 0)
      throw BuildFailure('Cannot hash kernel source diff');
    final bytes = BytesBuilder()..add(diff.stdout as List<int>);
    final sorted = [...names]..sort();
    for (final name in sorted) {
      final file = p.join(source, name);
      bytes.add(utf8.encode('$name\u0000'));
      // lstat mode is part of Python provenance; POSIX stat output preserves
      // the same mode including the symlink type without dereferencing it.
      final modeResult = await runner.capture('stat', [
        Platform.isMacOS ? '-f' : '-c',
        Platform.isMacOS ? '%p' : '%f',
        file,
      ]);
      final mode = int.parse(
        modeResult.stdout.toString().trim(),
        radix: Platform.isMacOS ? 8 : 16,
      );
      bytes.add(utf8.encode('$mode\u0000'));
      bytes.add(
        FileSystemEntity.isLinkSync(file)
            ? utf8.encode(Link(file).targetSync())
            : File(file).readAsBytesSync(),
      );
    }
    return (
      value: {
        'sha256': sha256.convert(bytes.takeBytes()).toString(),
        'untracked': names,
      },
      dirty: (diff.stdout as List<int>).isNotEmpty || names.isNotEmpty,
    );
  }

  Future<void> reset() async {
    if ((await sourceState()).dirty) {
      throw BuildFailure(
        'Kernel source has uncommitted changes; refusing to discard local edits.',
      );
    }
    if (state.existsSync()) state.deleteSync();
  }

  Future<void> prepare() async {
    // The submodule commit now owns all Y2 drivers and its device tree.
    // Never patch, reset, or silently switch a developer's kernel checkout.
    if (state.existsSync()) state.deleteSync();
    final actual = await sourceState();
    if (actual.dirty) {
      throw BuildFailure(
        'Kernel source has uncommitted changes. Commit them in the kernel fork '
        'before building; no source was changed.',
      );
    }
    final deviceTree = File(
      p.join(source, 'arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts'),
    );
    if (!deviceTree.existsSync()) {
      throw BuildFailure(
        'Kernel checkout is missing the Y2 device tree. Initialize the pinned '
        'Tempo kernel submodule before building.',
      );
    }
    final base = (await git(['rev-parse', 'HEAD'])).stdout.toString().trim();
    final tree = (await git([
      'rev-parse',
      'HEAD^{tree}',
    ])).stdout.toString().trim();
    state.parent.createSync(recursive: true);
    state.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'base': base, 'tree': tree, 'source': actual.value})}\n',
    );
    stdout.writeln('Verified committed Tempo kernel $base');
  }
}

Future<void> renderInitramfs(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
) async {
  final output = repo.path('build/os/initramfs');
  final hostname = config.string('device.hostname');
  final size = int.tryParse(config.string('rootfs.size_mb'));
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$').hasMatch(hostname) ||
      size == null ||
      size <= 0)
    throw BuildFailure('Invalid hostname or rootfs.size_mb for initramfs');
  Directory(output).createSync(recursive: true);
  final substitutions = {
    '@HOSTNAME@': hostname,
    '@ROOTFS_SIZE_MB@': '$size',
    '@ROOT@': repo.root,
    '@INIT@': p.join(output, 'init'),
  };
  for (final mapping in {
    'init.in': 'init',
    'initramfs.list': 'initramfs.list',
  }.entries) {
    var text = File(
      repo.path('platform/rootfs/initramfs/${mapping.key}'),
    ).readAsStringSync();
    for (final substitution in substitutions.entries)
      text = text.replaceAll(substitution.key, substitution.value);
    if (RegExp(r'@[A-Z_]+@').hasMatch(text))
      throw BuildFailure('Unsubstituted placeholder in ${mapping.key}');
    File(p.join(output, mapping.value)).writeAsStringSync(text);
  }
  await runner.run('chmod', ['755', p.join(output, 'init')]);
}

Future<void> buildInitramfs(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
) async {
  await renderInitramfs(repo, config, runner);
  final output = repo.path('build/os/initramfs');
  final busybox = repo.path('platform/rootfs/initramfs/busybox/busybox-armv7l');
  if (!File(busybox).existsSync())
    throw BuildFailure('Missing busybox: $busybox');
  final generator = repo.path('build/os/kernel/usr/gen_init_cpio');
  if (!File(generator).existsSync())
    await Toolchain(repo, runner).run([
      'make',
      '-C',
      repo.path('platform/kernel/linux'),
      'O=${repo.path('build/os/kernel')}',
      'usr/gen_init_cpio',
    ]);
  final lines = [
    'dir /dev 0755 0 0',
    'nod /dev/console 0600 0 0 c 5 1',
    'nod /dev/null 0666 0 0 c 1 3',
    'dir /proc 0755 0 0',
    'dir /sys 0755 0 0',
    'dir /run 0755 0 0',
    'dir /bin 0755 0 0',
    'file /bin/busybox $busybox 0755 0 0',
    'slink /bin/sh busybox 0777 0 0',
    'file /init ${p.join(output, 'init')} 0755 0 0',
  ];
  final payload = Directory(repo.path('build/os/rootfs/plymouth-payload'));
  if (payload.existsSync()) {
    final theme = Directory(
      p.join(payload.path, 'usr/share/plymouth/themes/tempo'),
    );
    if (theme.existsSync())
      for (final file in Directory(
        repo.path('platform/splash/plymouth/tempo'),
      ).listSync().whereType<File>())
        file.copySync(p.join(theme.path, p.basename(file.path)));
    final entries = payload.listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final relative = p.relative(entry.path, from: payload.path);
      if (RegExp(r'\s').hasMatch(entry.path))
        throw BuildFailure(
          'gen_init_cpio manifest paths cannot contain whitespace: ${entry.path}',
        );
      if (entry is Directory) lines.add('dir /$relative 0755 0 0');
      if (entry is File)
        lines.add(
          'file /$relative ${entry.path} 0${(entry.statSync().mode & 0xfff).toRadixString(8)} 0 0',
        );
      if (entry is Link)
        lines.add('slink /$relative ${entry.targetSync()} 0777 0 0');
    }
  }
  final manifest = File(p.join(output, 'external.list'))
    ..writeAsStringSync('${lines.join('\n')}\n');
  final archive = File(p.join(output, 'initramfs.cpio.gz'));
  final child = await Process.start(generator, [manifest.path]);
  final errors = child.stderr.transform(utf8.decoder).join();
  try {
    final sink = archive.openWrite();
    try {
      await sink.addStream(child.stdout.transform(GZipCodec(level: 9).encoder));
    } finally {
      await sink.close();
    }
    if (await child.exitCode != 0)
      throw BuildFailure('gen_init_cpio failed: ${await errors}');
    await errors;
  } catch (_) {
    child.kill();
    if (archive.existsSync()) archive.deleteSync();
    rethrow;
  }
}

Future<int> kernelCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  final action = args.isEmpty ? 'build' : args.removeAt(0);
  if (action == 'rev')
    return runner.run('git', [
      '-C',
      repo.path('platform/kernel/linux'),
      'log',
      '-1',
      '--format=%H %d %s',
    ]);
  if (action == 'reset') {
    if (args.isNotEmpty) throw BuildFailure('Unexpected reset arguments', 2);
    await KernelSource(repo, runner).reset();
    return 0;
  }
  if (action == 'clean') {
    if (args.isNotEmpty) throw BuildFailure('Unexpected clean arguments', 2);
    final directory = Directory(repo.path('build/os/kernel'));
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    final initramfs = Directory(repo.path('build/os/initramfs'));
    if (initramfs.existsSync()) initramfs.deleteSync(recursive: true);
    return 0;
  }
  if (action == 'prepare') {
    if (args.isNotEmpty) throw BuildFailure('Unexpected prepare arguments', 2);
    await KernelSource(repo, runner).prepare();
    return 0;
  }
  if (action == 'build') {
    if (args.isNotEmpty)
      throw BuildFailure('Unexpected kernel build arguments', 2);
    await KernelSource(repo, runner).prepare();
    await renderInitramfs(repo, config, runner);
    final output = repo.path('build/os/kernel');
    Directory(output).createSync(recursive: true);
    var fragment = File(
      repo.path('platform/kernel/config/y2.config'),
    ).readAsStringSync().replaceAll('@ROOT@', repo.root);
    fragment = fragment.replaceAll(
      repo.path('platform/rootfs/initramfs/initramfs.list'),
      repo.path('build/os/initramfs/initramfs.list'),
    );
    File(p.join(output, 'y2.config')).writeAsStringSync(fragment);
    final toolchain = Toolchain(repo, runner);
    final make = [
      'make',
      '-C',
      repo.path('platform/kernel/linux'),
      'O=$output',
    ];
    await toolchain.run([...make, 'multi_v7_defconfig']);
    File(
      p.join(output, '.config'),
    ).writeAsStringSync(fragment, mode: FileMode.append);
    await toolchain.run([...make, 'olddefconfig']);
    await toolchain.run([
      ...make,
      '-j${Platform.numberOfProcessors}',
      'zImage',
      'mediatek/mt6582-innioasis-y2.dtb',
    ]);
    await buildInitramfs(repo, config, runner);
  } else if (action != 'bootimg') {
    throw BuildFailure('Expected os kernel build, prepare, or bootimg', 2);
  }
  final options = <String, String>{};
  while (args.isNotEmpty) {
    final name = args.removeAt(0);
    if (!['--max-size', '--dtb', '--ramdisk', '--output'].contains(name) ||
        args.isEmpty)
      throw BuildFailure('Invalid bootimg option: $name', 2);
    options[name] = args.removeAt(0);
  }
  final kernelDir = repo.path('build/os/kernel');
  final zImage = File(
    p.join(kernelDir, 'arch/arm/boot/zImage'),
  ).readAsBytesSync();
  final dtb = File(
    options['--dtb'] ??
        p.join(kernelDir, 'arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dtb'),
  );
  final ramdiskFile = File(
    options['--ramdisk'] ?? repo.path('build/os/initramfs/initramfs.cpio.gz'),
  );
  var tree = dtb.readAsBytesSync();
  var ramdisk = Uint8List(9 * 2048);
  if (ramdiskFile.existsSync()) {
    ramdisk = ramdiskFile.readAsBytesSync();
    final patched = dtb.copySync(p.join(kernelDir, 'boot-initrd-$pid.dtb'));
    try {
      for (final entry in {
        'linux,initrd-start': 0x84000000,
        'linux,initrd-end': 0x84000000 + ramdisk.length,
      }.entries)
        await Toolchain(repo, runner).run([
          'fdtput',
          '-p',
          '-t',
          'x',
          patched.path,
          '/chosen',
          entry.key,
          '0x${entry.value.toRadixString(16)}',
        ]);
      tree = patched.readAsBytesSync();
    } finally {
      patched.deleteSync();
    }
  } else if (options.containsKey('--ramdisk')) {
    throw BuildFailure('Explicit ramdisk does not exist: ${ramdiskFile.path}');
  }
  final limit = int.parse(
    options['--max-size'] ?? config.string('device.partitions.bootimg_size'),
  );
  final image = bootImage(
    mtkHeader([...zImage, ...tree], 'KERNEL'),
    mtkHeader(ramdisk, 'ROOTFS'),
    maxSize: limit,
  );
  final output = File(options['--output'] ?? p.join(kernelDir, 'boot.img'));
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(image, flush: true);
  stdout.writeln(
    'Boot image: ${output.path} (${image.length} bytes, ${limit - image.length} bytes free)',
  );
  return 0;
}
