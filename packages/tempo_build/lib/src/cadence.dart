import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'context.dart';
import 'process.dart';

/// Build the Cadence-owned source tree with the same pinned Dart as tempod.
/// Source is explicit while Cadence's public repository is being prepared.
Future<int> cadenceCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  if (args.length != 1 || args.single != 'build') {
    throw BuildFailure('Expected cadence build', 2);
  }
  final source = p.absolute(
    Platform.environment['TEMPO_CADENCE_SOURCE'] ??
        repo.path('third_party/cadence'),
  );
  final provenance = File(p.join(source, 'TEMPO_UPSTREAM_REVISION'));
  if (!provenance.existsSync() ||
      !RegExp(
        r'^[a-f0-9]{40}$',
      ).hasMatch(provenance.readAsStringSync().trim())) {
    throw BuildFailure(
      'Cadence source requires TEMPO_UPSTREAM_REVISION containing its exact commit. '
      'Set TEMPO_CADENCE_SOURCE to the pinned source archive directory.',
    );
  }
  final revision = provenance.readAsStringSync().trim();
  final dart = Platform.environment['TEMPO_DAEMON_DART'] ??
      (await FlutterSdk.discover(config, runner,
        version: config.get('daemon.toolchain_version', fallback: '3.47.2').toString(),
      )).dart;
  final version = config
      .get('daemon.dart_version', fallback: '3.13.2')
      .toString();
  final actual = await runner.capture(dart, ['--version']);
  if (!'${actual.stdout}${actual.stderr}'.contains(
    'Dart SDK version: $version ',
  )) {
    throw BuildFailure('Cadence requires Dart $version');
  }
  await runner.run(dart, [
    'pub',
    'get',
    '--enforce-lockfile',
  ], workingDirectory: source);
  final output = repo.path('build/os/cadence/arm');
  await runner.run(dart, [
    'build',
    'cli',
    '--target',
    'daemon/bin/cadenced.dart',
    '--target-os',
    'linux',
    '--target-arch',
    'arm',
    '--output',
    output,
  ], workingDirectory: source);
  await Toolchain(repo, runner).run(
    [
      'cargo',
      'build',
      '--release',
      '--locked',
      '--target',
      'armv7-unknown-linux-gnueabihf',
      '-p',
      'cadence-probe',
    ],
    workingDirectory: source,
    environment: {
      'CARGO_TARGET_DIR': repo.path('build/cadence-rust'),
      'CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER':
          'arm-linux-gnueabihf-gcc',
      'CC_armv7_unknown_linux_gnueabihf': 'arm-linux-gnueabihf-gcc',
    },
    readOnlyPaths: p.isWithin(repo.root, source) ? [] : [source],
  );
  final bundle = p.join(output, 'bundle');
  await File(
    repo.path(
      'build/cadence-rust/armv7-unknown-linux-gnueabihf/release/libcadence_probe.so',
    ),
  ).copy(p.join(bundle, 'lib/libcadence_probe.so'));
  await File(p.join(source, 'LICENSE')).copy(p.join(bundle, 'LICENSE'));
  final hashes = <String, String>{};
  for (final file in Directory(
    bundle,
  ).listSync(recursive: true).whereType<File>()) {
    if (p.basename(file.path) == 'manifest.json') continue;
    hashes[p.relative(file.path, from: bundle)] =
        (await sha256.bind(file.openRead()).first).toString();
  }
  File(p.join(bundle, 'manifest.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'sourceCommit': revision, 'dart': version, 'target': 'arm', 'files': hashes})}\n',
  );
  await verifyCadenceBundle(bundle);
  stdout.writeln('Cadence bundle: $bundle ($revision)');
  return 0;
}

Future<Map<String, String>> verifyCadenceBundle(String directory) async {
  final manifest = File(p.join(directory, 'manifest.json'));
  if (!manifest.existsSync())
    throw BuildFailure('Build Cadence before staging rootfs');
  final document = jsonDecode(manifest.readAsStringSync());
  if (document is! Map ||
      document['target'] != 'arm' ||
      document['sourceCommit'] is! String ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(document['sourceCommit'] as String) ||
      document['files'] is! Map) {
    throw BuildFailure('Invalid Cadence ARM bundle manifest');
  }
  final files = <String, String>{};
  for (final entry in (document['files'] as Map).entries) {
    if (entry.key is! String || entry.value is! String) {
      throw BuildFailure('Invalid Cadence bundle entry');
    }
    final relative = entry.key as String;
    if (p.isAbsolute(relative) ||
        relative.split(RegExp(r'[/\\]')).contains('..') ||
        RegExp(r'[\x00-\x1f]').hasMatch(relative) ||
        relative == 'manifest.json') {
      throw BuildFailure('Invalid Cadence bundle path: $relative');
    }
    final path = p.join(directory, relative);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file ||
        (await sha256.bind(File(path).openRead()).first).toString() !=
            entry.value) {
      throw BuildFailure('Cadence bundle checksum failed: $relative');
    }
    files[relative] = entry.value as String;
  }
  for (final path in [
    'bin/cadenced',
    'lib/libcadence_probe.so',
    'lib/libsqlite3.so',
  ]) {
    if (!files.containsKey(path))
      throw BuildFailure('Incomplete Cadence bundle: $path');
    final handle = File(p.join(directory, path)).openSync();
    final header = handle.readSync(20);
    handle.closeSync();
    if (header.length != 20 ||
        header[0] != 127 ||
        header[1] != 69 ||
        header[2] != 76 ||
        header[3] != 70 ||
        header[4] != 1 ||
        header[5] != 1 ||
        header[18] != 40 ||
        header[19] != 0) {
      throw BuildFailure(
        'Cadence artifact is not ARM32 little-endian ELF: $path',
      );
    }
  }
  if (!files.containsKey('LICENSE'))
    throw BuildFailure('Cadence license missing');
  return files;
}
