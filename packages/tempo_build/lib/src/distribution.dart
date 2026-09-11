import 'dart:convert';
import 'dart:io';
import 'package:file/local.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';
import 'splash.dart';
import 'recovery.dart';
import 'radio_distribution.dart';
import 'tempo_layout.dart';
import 'rootfs.dart' show withRootfsLock;

const rootfsPartitions = {
  'LOGO',
  'EBR2',
  'EXPDB',
  'ANDROID',
  'CACHE',
  'USRDATA',
  'FAT',
};

class ScatterDocument {
  ScatterDocument(this.header, this.blocks);
  final List<String> header;
  final List<List<String>> blocks;
  factory ScatterDocument.parse(String text) {
    final header = <String>[], blocks = <List<String>>[];
    List<String>? current;
    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('- partition_index:')) {
        current = [];
        blocks.add(current);
      }
      (current ?? header).add('$line\n');
    }
    if (blocks.isEmpty)
      throw const FormatException('Scatter has no partitions');
    return ScatterDocument(header, blocks);
  }
  static String field(List<String> block, String key) {
    final line = block
        .where((line) => line.trimLeft().startsWith('$key:'))
        .firstOrNull;
    if (line == null) throw FormatException('Missing scatter field $key');
    return line.substring(line.indexOf(':') + 1).trim();
  }

  static void setField(List<String> block, String key, String value) {
    final index = block.indexWhere(
      (line) => line.trimLeft().startsWith('$key:'),
    );
    if (index < 0) throw FormatException('Missing scatter field $key');
    final line = block[index];
    block[index] =
        '${line.substring(0, line.length - line.trimLeft().length)}$key: $value\n';
  }

  String encode() => header.join() + blocks.map((block) => block.join()).join();
}

Future<void> copyRange(
  RandomAccessFile source,
  RandomAccessFile target,
  int offset,
  int length,
) async {
  await source.setPosition(offset);
  while (length > 0) {
    final bytes = await source.read(
      length < 4 * 1024 * 1024 ? length : 4 * 1024 * 1024,
    );
    if (bytes.isEmpty) throw BuildFailure('Short source image');
    if (bytes.every((byte) => byte == 0)) {
      await target.setPosition(await target.position() + bytes.length);
    } else {
      await target.writeFrom(bytes);
    }
    length -= bytes.length;
  }
}

Future<Map<String, Object>> generateScatter({
  required String scatter,
  required String destination,
  required String rootfs,
  required int rootfsRaw,
  required int rootfsSpan,
  required int bootimgRaw,
  required int emmcSize,
  Map<String, String> chain = const {},
}) async {
  final folder = p.dirname(destination),
      document = ScatterDocument.parse(File(scatter).readAsStringSync());
  final byName = {
    for (final block in document.blocks)
      ScatterDocument.field(block, 'partition_name'): block,
  };
  String field(List<String> block, String key) =>
      ScatterDocument.field(block, key);
  int number(List<String> block, String key) => int.parse(field(block, key));
  final boot = byName['BOOTIMG'];
  if (boot == null) throw BuildFailure('Scatter BOOTIMG partition is missing');
  final bias = bootimgRaw - number(boot, 'physical_start_addr');
  if (bias != 0xb80000 || rootfsRaw < bias)
    throw BuildFailure('Unexpected Y2 address mapping');
  final image = File(rootfs), size = image.lengthSync();
  if (size <= 0 || size > rootfsSpan || rootfsRaw + rootfsSpan > emmcSize)
    throw BuildFailure('Rootfs image exceeds configured USER range');
  final end = rootfsRaw + size, logo = byName['LOGO'];
  if (logo == null) throw BuildFailure('Scatter LOGO partition is missing');
  final logoStart = number(logo, 'physical_start_addr') + bias;
  if (!(logoStart < rootfsRaw &&
      rootfsRaw < logoStart + number(logo, 'partition_size')))
    throw BuildFailure('Unexpected historical LOGO/rootfs overlap');
  final logoFile = File(p.join(folder, 'logo.img'));
  if (logoFile.lengthSync() > rootfsRaw - logoStart)
    throw BuildFailure('LOGO image overlaps rootfs');
  int span(List<String> block) {
    final size = number(block, 'partition_size');
    if (field(block, 'partition_name') == 'FAT' && size == 0) {
      final reserved = byName['BMTPOOL'];
      if (reserved == null)
        throw BuildFailure('Scatter BMTPOOL partition is missing');
      return emmcSize -
          number(reserved, 'partition_size') -
          number(block, 'physical_start_addr') -
          bias;
    }
    return size;
  }

  final downloads = {
    'BOOTIMG': 'boot.img',
    'RECOVERY': 'recovery.img',
    ...chain,
  };
  final pieces = <Map<String, Object>>[];
  var cursor = rootfsRaw;
  for (final block in document.blocks) {
    final name = field(block, 'partition_name');
    if (field(block, 'region') != 'EMMC_USER' ||
        field(block, 'is_reserved') == 'true')
      continue;
    final start = number(block, 'physical_start_addr') + bias,
        stop = number(block, 'physical_start_addr') + bias + span(block);
    final low = start > rootfsRaw ? start : rootfsRaw,
        high = stop < end ? stop : end;
    if (high <= low) continue;
    if (!rootfsPartitions.contains(name) || low != cursor)
      throw BuildFailure('Rootfs crosses unexpected partition or gap: $name');
    if (low != start && name != 'LOGO')
      throw BuildFailure('Unhandled prefix outside rootfs: $name');
    pieces.add({
      'partition': name,
      'file': 'rootfs-${name.toLowerCase()}.bin',
      'raw_start': start,
      'image_offset': low - start,
      'rootfs_offset': low - rootfsRaw,
      'length': high - low,
    });
    cursor = high;
  }
  if (cursor != end)
    throw BuildFailure(
      'Stock partitions do not cover the complete rootfs image',
    );
  // Validate non-rootfs chain files before writing any split artifacts.
  for (final entry in downloads.entries) {
    final block = byName[entry.key];
    if (block == null ||
        File(p.join(folder, entry.value)).lengthSync() > span(block))
      throw BuildFailure(
        'Image exceeds or names unknown ${entry.key} partition',
      );
  }
  for (final piece in pieces) {
    final target = File(
      p.join(folder, piece['file'] as String),
    ).openSync(mode: FileMode.write);
    final source = image.openSync();
    try {
      if (piece['partition'] == 'LOGO') {
        final input = logoFile.openSync();
        try {
          await copyRange(input, target, 0, logoFile.lengthSync());
        } finally {
          input.closeSync();
        }
      }
      await target.setPosition(piece['image_offset'] as int);
      await copyRange(
        source,
        target,
        piece['rootfs_offset'] as int,
        piece['length'] as int,
      );
      await target.truncate(await target.position());
    } finally {
      source.closeSync();
      target.closeSync();
    }
    downloads[piece['partition'] as String] = piece['file'] as String;
  }
  final expected = (await sha256.bind(image.openRead()).first).toString();
  Stream<List<int>> reconstruct() async* {
    for (final piece in pieces) {
      final offset = piece['image_offset'] as int,
          length = piece['length'] as int;
      final file = File(p.join(folder, piece['file'] as String));
      if (file.lengthSync() < offset + length)
        throw BuildFailure('Short generated rootfs piece');
      yield* file.openRead(offset, offset + length);
    }
  }

  if ((await sha256.bind(reconstruct()).first).toString() != expected)
    throw BuildFailure('Split images do not reconstruct the rootfs');
  for (final block in document.blocks) {
    final name = field(block, 'partition_name'),
        enabled = downloads.containsKey(field(block, 'partition_name'));
    ScatterDocument.setField(block, 'file_name', downloads[name] ?? 'NONE');
    ScatterDocument.setField(block, 'is_download', '$enabled');
    if (enabled) {
      if (rootfsPartitions.contains(name)) {
        ScatterDocument.setField(block, 'type', 'NORMAL_ROM');
        ScatterDocument.setField(block, 'operation_type', 'UPDATE');
      }
      if (File(p.join(folder, downloads[name]!)).lengthSync() > span(block))
        throw BuildFailure('Image exceeds $name partition');
    }
  }
  File(destination).writeAsStringSync(document.encode());
  final manifest = <String, Object>{
    'raw_rootfs_start': rootfsRaw,
    'raw_rootfs_end': end,
    'user_bias': bias,
    'rootfs_sha256': expected,
    'pieces': pieces,
  };
  File(p.join(folder, 'rootfs-pieces.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  return manifest;
}

/// Translate the generated scatter into the installer's explicit raw USER map.
/// BOOT1 is deliberately absent: SPFT's raw GFH input is not a complete,
/// audited EMMC_BOOT/BRLYT image and must never be flashed as one.
Future<Map<String, Object>> installerManifest({
  required String scatter,
  required String version,
  int userBias = 0xb80000,
  String? icon,
  String? commit,
}) async {
  if (version.trim().isEmpty || userBias != 0xb80000) {
    throw BuildFailure('Invalid installer identity or Y2 address mapping');
  }
  final document = ScatterDocument.parse(File(scatter).readAsStringSync());
  final images = <Map<String, Object>>[];
  final ranges = <(int, int)>[];
  final names = <String>{};
  for (final block in document.blocks) {
    String field(String key) => ScatterDocument.field(block, key);
    if (field('is_download') != 'true' || field('region') != 'EMMC_USER') {
      continue;
    }
    final filename = field('file_name');
    if (p.basename(filename) != filename ||
        filename == '.' ||
        filename == '..' ||
        filename.contains('\\') ||
        !names.add(filename)) {
      throw BuildFailure('Unsafe or duplicate installer image name');
    }
    final file = File(p.join(p.dirname(scatter), filename));
    final length = file.lengthSync();
    final padded = (length + 511) ~/ 512 * 512;
    final start = int.parse(field('physical_start_addr')) + userBias;
    final span = int.parse(field('partition_size'));
    if (length == 0 ||
        start % 512 != 0 ||
        start < 0 ||
        start + padded > 0x1d2000000 ||
        (span > 0 && padded > span) ||
        ranges.any((range) => start < range.$2 && start + padded > range.$1)) {
      throw BuildFailure(
        'Invalid or overlapping installer range: ${field('partition_name')}',
      );
    }
    ranges.add((start, start + padded));
    Stream<List<int>> paddedBytes() async* {
      yield* file.openRead();
      if (padded > length) yield List<int>.filled(padded - length, 0);
    }

    images.add({
      'file': 'images/$filename',
      'size': padded,
      'sha256': (await sha256.bind(paddedBytes()).first).toString(),
      'writes': [
        {
          'name': field('partition_name'),
          'region': 'user',
          'source_offset': 0,
          'target_offset': start,
          'length': padded,
        },
      ],
    });
  }
  if (images.isEmpty) throw BuildFailure('Installer contains no images');
  return {
    'format': 'dev.artificery.tempo.y2-firmware',
    'format_version': 1,
    'device': {
      'id': 'innioasis-y2',
      'hardware_code': 0x6582,
      'hardware_subcode': 0x8a00,
      'storage': {'boot1': 0x400000, 'boot2': 0x400000, 'user': 0x1d2000000},
    },
    'firmware': {
      'id': 'tempo',
      'name': 'Tempo',
      'version': version,
      if (commit != null) 'commit': commit,
      if (icon != null) 'icon': icon,
    },
    'images': images,
  };
}

// Python belongs to the toolchain container. zipfile streams deflate and ZIP64
// without loading multi-gigabyte rootfs pieces into the developer CLI's heap.
const installerArchiveScript = r'''
import hashlib, json, os, sys, zipfile
manifest_path, source, destination = sys.argv[1:]
with open(manifest_path, 'rb') as stream:
    manifest_bytes = stream.read()
manifest = json.loads(manifest_bytes)
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED,
                     compresslevel=1, allowZip64=True) as archive:
    archive.writestr('manifest.json', manifest_bytes)
    for image in manifest['images']:
        digest = hashlib.sha256()
        count = 0
        with open(os.path.join(source, os.path.basename(image['file'])), 'rb') as stream:
            with archive.open(image['file'], 'w', force_zip64=True) as entry:
                while chunk := stream.read(1024 * 1024):
                    entry.write(chunk)
                    digest.update(chunk)
                    count += len(chunk)
                if count > image['size'] or image['size'] - count > 511:
                    raise ValueError('Image changed while packaging')
                padding = bytes(image['size'] - count)
                entry.write(padding)
                digest.update(padding)
        if digest.hexdigest() != image['sha256']:
            raise ValueError('Image changed while packaging')
with zipfile.ZipFile(destination) as archive:
    for image in manifest['images']:
        digest = hashlib.sha256()
        count = 0
        with archive.open(image['file']) as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
                count += len(chunk)
        if count != image['size'] or digest.hexdigest() != image['sha256']:
            raise ValueError('Packaged image failed verification')
''';

Future<void> writeInstallerArchive(
  Repository repo,
  CommandRunner runner, {
  required String scatter,
  required String version,
  required String destination,
  String? commit,
}) async {
  final manifest = await installerManifest(
    scatter: scatter,
    version: version,
    commit: commit,
    icon:
        'data:image/png;base64,${base64Encode(const LocalFileSystem().file(repo.path('assets/tempo/web/icon-192.png')).readAsBytesSync())}',
  );
  stdout.writeln('Compressing and verifying installer archive: $destination');
  final temporary = File('$destination.tmp.$pid');
  final metadata = File('$destination.manifest.$pid.json');
  try {
    metadata.writeAsStringSync(jsonEncode(manifest));
    await Toolchain(repo, runner).run([
      'python3',
      '-c',
      installerArchiveScript,
      metadata.path,
      p.dirname(scatter),
      temporary.path,
    ]);
    temporary.renameSync(destination);
  } finally {
    if (metadata.existsSync()) metadata.deleteSync();
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

Future<void> writeTempoInstallerArchive(
  Repository repo,
  CommandRunner runner, {
  required String directory,
  required String version,
  required String commit,
  required String destination,
}) async {
  final fs = const LocalFileSystem();
  final manifest = await tempoInstallerManifest(
    directory: fs.directory(directory),
    version: version,
    commit: commit,
    icon:
        'data:image/png;base64,${base64Encode(fs.file(repo.path('assets/tempo/web/icon-192.png')).readAsBytesSync())}',
  );
  final temporary = fs.file('$destination.tmp.$pid');
  final metadata = fs.file('$destination.manifest.$pid.json');
  try {
    metadata.writeAsStringSync(jsonEncode(manifest));
    await Toolchain(repo, runner).run([
      'python3',
      '-c',
      installerArchiveScript,
      metadata.path,
      directory,
      temporary.path,
    ]);
    temporary.renameSync(destination);
  } finally {
    if (metadata.existsSync()) metadata.deleteSync();
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

Future<int> distributionCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) => withRootfsLock(
  repo,
  () => _distributionCommand(repo, config, runner, args),
);

Future<int> _distributionCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'dist [--full] [--with-rootfs]\nPackage kernel, splash and rootfs into an SPFT Download Only set.',
    );
    return 0;
  }
  for (final arg in args)
    if (!['--full', '--with-rootfs'].contains(arg))
      throw BuildFailure('Unexpected dist argument: $arg', 2);
  final out = repo.path('build/dist'),
      images = p.join(repo.path('build/dist'), 'images'),
      spft = p.join(repo.path('build/dist'), 'spft');
  if (int.parse(config.string('device.partitions.rootfs_offset')) !=
          TempoLayout.rootfsOffset ||
      int.parse(config.string('device.partitions.rootfs_size')) !=
          TempoLayout.rootfsSize ||
      int.parse(config.string('device.partitions.bootimg_offset')) !=
          TempoLayout.bootOffset ||
      int.parse(config.string('device.partitions.emmc_size')) !=
          TempoLayout.userSize) {
    throw BuildFailure(
      'Device configuration does not match the Tempo disk layout',
    );
  }
  final hostname = config.string('device.hostname'),
      boot = File(repo.path('build/os/kernel/boot.img')),
      rootfs = File(
        repo.path('build/os/rootfs/${config.string('device.hostname')}.ext4'),
      );
  var stock = config.string('firmware.stock_rom');
  if (!p.isAbsolute(stock)) stock = repo.path(stock);
  for (final file in [
    boot,
    rootfs,
    File(p.join(stock, 'MT6582_Android_scatter.txt')),
  ])
    if (!file.existsSync())
      throw BuildFailure('Missing distribution input: ${file.path}');
  final handle = boot.openSync();
  late String magic;
  try {
    magic = ascii.decode(handle.readSync(8));
  } finally {
    handle.closeSync();
  }
  if (magic != 'ANDROID!' ||
      boot.lengthSync() >
          int.parse(config.string('device.partitions.bootimg_size')))
    throw BuildFailure('Invalid or oversized BOOTIMG');
  if (rootfs.lengthSync() >
      int.parse(config.string('device.partitions.rootfs_size')))
    throw BuildFailure('Rootfs image exceeds its partition');
  if ((await runner.capture('mountpoint', [
        '-q',
        repo.path('build/os/rootfs/mnt'),
      ], check: false)).exitCode ==
      0)
    throw BuildFailure('Rootfs is mounted; wait for its build to finish');
  await Toolchain(repo, runner).run(['e2fsck', '-fn', rootfs.path]);
  await Toolchain(
    repo,
    runner,
  ).run(['python3', '-c', checkRadioImageScript, rootfs.path]);
  Directory(images).createSync(recursive: true);
  Directory(spft).createSync(recursive: true);
  await buildRecovery(repo, runner);
  File(
    repo.path('build/recovery/recovery.img'),
  ).copySync(p.join(images, 'recovery.img'));
  boot.copySync(p.join(images, 'boot.img'));
  await splashCommand(repo, config, runner, [
    'build',
    if (!File(p.join(stock, 'logo.bin')).existsSync()) '--bare',
    '--template',
    p.join(stock, 'logo.bin'),
  ]);
  File(
    repo.path('build/os/splash/logo.bin'),
  ).copySync(p.join(images, 'logo.img'));
  final compressed = File(p.join(images, '$hostname.ext4.gz'));
  if (!compressed.existsSync() ||
      !compressed.lastModifiedSync().isAfter(rootfs.lastModifiedSync())) {
    final temporary = File('${compressed.path}.tmp.$pid');
    final sink = temporary.openWrite();
    try {
      await sink.addStream(
        rootfs.openRead().transform(GZipCodec(level: 1).encoder),
      );
      await sink.close();
      temporary.renameSync(compressed.path);
    } catch (_) {
      await sink.close();
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }
  Future<void> checksums(String directory, List<String> names) async {
    final lines = <String>[];
    for (final name in names)
      lines.add(
        '${await sha256.bind(File(p.join(directory, name)).openRead()).first}  $name',
      );
    File(
      p.join(directory, 'SHA256SUMS'),
    ).writeAsStringSync('${lines.join('\n')}\n');
  }

  await checksums(images, [
    'boot.img',
    'recovery.img',
    'logo.img',
    '$hostname.ext4.gz',
  ]);
  for (final name in ['boot.img', 'recovery.img', 'logo.img'])
    File(p.join(images, name)).copySync(p.join(spft, name));
  final chain = <String, String>{};
  if (args.contains('--full')) {
    final preloaders =
        Directory(stock)
            .listSync()
            .whereType<File>()
            .where(
              (file) =>
                  p.basename(file.path).startsWith('preloader_') &&
                  file.path.endsWith('.bin'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (preloaders.isEmpty) throw BuildFailure('No stock preloader in $stock');
    chain.addAll({
      'PRELOADER': p.basename(preloaders.first.path),
      'MBR': 'MBR',
      'EBR1': 'EBR1',
      'UBOOT': 'lk.bin',
      'SEC_RO': 'secro.img',
    });
    for (final name in chain.values)
      File(p.join(stock, name)).copySync(p.join(spft, name));
  }
  stdout.writeln('Splitting and verifying rootfs images for packaging');
  final pieces = await generateScatter(
    scatter: p.join(stock, 'MT6582_Android_scatter.txt'),
    destination: p.join(spft, 'Y2_MT6582_scatter.txt'),
    rootfs: rootfs.path,
    rootfsRaw: int.parse(config.string('device.partitions.rootfs_offset')),
    rootfsSpan: int.parse(config.string('device.partitions.rootfs_size')),
    bootimgRaw: int.parse(config.string('device.partitions.bootimg_offset')),
    emmcSize: int.parse(config.string('device.partitions.emmc_size')),
    chain: chain,
  );
  for (final name in [
    'Y2_MT6582_scatter-rootfs.txt',
    'MT6582_Android_scatter.txt',
    'MT6582_Android_scatter-rootfs.txt',
  ]) {
    final file = File(p.join(spft, name));
    if (file.existsSync()) file.deleteSync();
  }
  File(repo.path('platform/firmware/DA.img')).copySync(p.join(spft, 'DA.img'));
  Future<String> git(String directory, List<String> args) async =>
      (await runner.capture('git', [
        '-C',
        directory,
        ...args,
      ])).stdout.toString();
  Future<String> digest(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();
  final modules = <String, Object>{};
  for (final name in ['platform/kernel/linux', 'app/flutter-pi/flutter-pi']) {
    final path = repo.path(name), untracked = <String, String>{};
    for (final file in (await git(path, [
      'ls-files',
      '--others',
      '--exclude-standard',
      '-z',
    ])).split('\u0000').where((name) => name.isNotEmpty))
      untracked[file] = await digest(p.join(path, file));
    modules[name] = {
      'commit': (await git(path, ['rev-parse', 'HEAD'])).trim(),
      'tracked_diff_sha256': sha256
          .convert(utf8.encode(await git(path, ['diff', 'HEAD', '--binary'])))
          .toString(),
      'untracked_files': untracked,
    };
  }
  final commit = (await git(repo.root, ['rev-parse', 'HEAD'])).trim();
  final provenance = {
    'commit': commit,
    'worktree_status': const LineSplitter().convert(
      await git(repo.root, ['status', '--porcelain']),
    ),
    'submodules': modules,
    'kernel_source': jsonDecode(
      File(repo.path('build/os/kernel/tempo-source.json')).readAsStringSync(),
    ),
    'bluetooth_payload': jsonDecode(
      File(
        repo.path('build/os/bluetooth/build-manifest.json'),
      ).readAsStringSync(),
    ),
    'kernel_config_sha256': await digest(repo.path('build/os/kernel/.config')),
    'public_config_sha256': await digest(repo.path('config.yaml')),
    'dart_lock_sha256': await digest(repo.path('pubspec.lock')),
  };
  File(p.join(spft, 'build-provenance.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(provenance)}\n',
  );
  File(p.join(spft, 'README.md')).writeAsStringSync('''# Legacy scatter export

Source commit: `$commit`. See build-provenance.json and SHA256SUMS.

This directory preserves the vendor scatter layout and split rootfs images for
legacy inspection. Install Tempo using the sibling .y2-firmware package in
Toolbox: it includes Tempo's native layout and sector-zero partition table.
The scatter export does not install that MBR and is not the native installer.

Toolbox also accepts original vendor scatter ROM packages directly; an external
SP Flash Tool installation is not required.
''');
  final names = [
    'boot.img',
    'recovery.img',
    for (final piece in pieces['pieces'] as List<Map<String, Object>>)
      piece['file'] as String,
    'DA.img',
    'Y2_MT6582_scatter.txt',
    'rootfs-pieces.json',
    'build-provenance.json',
    'README.md',
    ...chain.values,
  ];
  await checksums(spft, names);
  final installer = p.join(out, '$hostname.y2-firmware');
  final nativeRootfs = const LocalFileSystem().file(
    p.join(images, 'rootfs.ext4'),
  );
  final source = await rootfs.open();
  final target = await nativeRootfs.open(mode: FileMode.write);
  try {
    final length = await rootfs.length();
    await copyRange(source, target, 0, length);
    await target.truncate(length);
  } finally {
    await source.close();
    await target.close();
  }
  await writeTempoInstallerArchive(
    repo,
    runner,
    directory: images,
    version: config.string('firmware.version'),
    commit: commit,
    destination: installer,
  );
  if (args.contains('--full')) {
    stdout.writeln(
      'Installer preserves BOOT1; the raw stock preloader remains SPFT-only.',
    );
  }
  stdout.writeln(
    'Distribution: $out\nInstaller: $installer\nUse Download Only with all selected rootfs pieces.',
  );
  return 0;
}
