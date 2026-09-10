import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:toolbox_core/live_device.dart';
import 'context.dart';
import 'process.dart';
import 'daemon_native.dart';
import 'device.dart' show deviceTransport;

class VerifiedDaemonBundle {
  VerifiedDaemonBundle(this.directory, this.files);
  final String directory;
  final Map<String, String> files;
}

Future<VerifiedDaemonBundle> verifyDaemonBundle(String directory) async {
  directory = p.normalize(p.absolute(directory));
  final manifest = File(p.join(directory, 'manifest.json'));
  if (!manifest.existsSync())
    throw BuildFailure('Missing daemon bundle manifest: ${manifest.path}');
  final document = jsonDecode(manifest.readAsStringSync());
  if (document is! Map ||
      document['target'] != 'arm' ||
      document['native'] != true ||
      document['files'] is! Map)
    throw BuildFailure(
      'Daemon bundle must be target arm with its complete native runtime',
    );
  final hashes = <String, String>{};
  for (final entry in (document['files'] as Map).entries) {
    if (entry.key is! String || entry.value is! String)
      throw BuildFailure('Invalid daemon manifest entry');
    final relative = entry.key as String, expected = entry.value as String;
    if (p.isAbsolute(relative) ||
        relative.split(RegExp(r'[/\\]')).contains('..') ||
        RegExp(r'[\x00-\x1f]').hasMatch(relative) ||
        relative == 'manifest.json' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected))
      throw BuildFailure('Invalid daemon manifest path or checksum: $relative');
    final path = p.normalize(p.join(directory, relative));
    if (!p.isWithin(directory, path) ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file)
      throw BuildFailure(
        'Daemon manifest path is not a regular bundle file: $relative',
      );
    if ((await sha256.bind(File(path).openRead()).first).toString() != expected)
      throw BuildFailure(
        'Daemon artifact failed manifest verification: $relative',
      );
    hashes[relative] = expected;
  }
  // No SQLite here any more: the media database left with the embedded
  // scanner, and cadenced brings its own copy in its own bundle.
  for (final required in [
    'bin/tempod',
    'bin/tempod-native',
    'lib/libtempod_native.so',
  ]) {
    if (!hashes.containsKey(required))
      throw BuildFailure('Incomplete daemon bundle; missing $required');
    final file = File(p.join(directory, required)).openSync();
    late Uint8List header;
    try {
      header = file.readSync(20);
    } finally {
      file.closeSync();
    }
    if (header.length < 20 ||
        header[0] != 127 ||
        header[1] != 69 ||
        header[2] != 76 ||
        header[3] != 70 ||
        header[4] != 1 ||
        header[5] != 1 ||
        header[18] != 40 ||
        header[19] != 0)
      throw BuildFailure(
        '$required is not an ARM32 little-endian ELF artifact',
      );
  }
  for (final entity in Directory(
    directory,
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final relative = p.relative(entity.path, from: directory);
    if (relative != 'manifest.json' && !hashes.containsKey(relative))
      throw BuildFailure('Unmanifested daemon bundle file: $relative');
  }
  return VerifiedDaemonBundle(directory, Map.unmodifiable(hashes));
}

Map<String, String> daemonServiceDropins(BuildConfig config) {
  final user = config.string('user.name');
  if (!RegExp(r'^[a-zA-Z0-9_-]+\$?$').hasMatch(user))
    throw BuildFailure('Invalid daemon service user name');
  return {
    '/etc/systemd/system/tempod.socket.d/10-group.conf':
        '[Socket]\nSocketGroup=$user\n',
    '/etc/systemd/system/tempod.service.d/20-runtime.conf':
        '[Service]\nExecStartPre=\nExecStartPre=/usr/local/sbin/tempod --init-credentials --credential-group $user\nEnvironment=TEMPOD_PROFILE_HOME=/home/$user\nEnvironment=TEMPOD_PROFILE_USER=$user\nEnvironment=TEMPOD_SD_ROOT=/mnt/sd\nEnvironment=TEMPOD_SETTINGS_FILE=/home/$user/.config/tempo/settings.json\n',
    '/etc/systemd/system/tempo.service.d/20-daemon.conf':
        '[Service]\nEnvironment=TEMPOD_API_URL=http://127.0.0.1:8765\nEnvironment=TEMPOD_API_TOKEN_FILE=/var/lib/tempod/credentials/api-token\nEnvironment=TEMPOD_OWNER_TOKEN_FILE=/var/lib/tempod/credentials/owner-token\n',
  };
}

Future<int> daemonMaintenanceCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  final action = args.isEmpty ? 'check' : args.removeAt(0);
  if (action == 'clean') {
    if (args.isNotEmpty)
      throw BuildFailure('Unexpected daemon clean arguments', 2);
    final output = Directory(repo.path('build/os/daemon'));
    if (output.existsSync()) output.deleteSync(recursive: true);
    return 0;
  }
  if (action == 'check') {
    if (args.isNotEmpty)
      throw BuildFailure('Unexpected daemon check arguments', 2);
    final dart =
        Platform.environment['TEMPO_DAEMON_DART'] ??
        (await FlutterSdk.discover(
          config,
          runner,
          version: config
              .get('daemon.toolchain_version', fallback: '3.47.2')
              .toString(),
        )).dart;
    final failures = <String>[];
    for (final command in [
      ['fmt', '--all', '--', '--check'],
      ['clippy', '-p', 'tempod', '--all-targets', '--', '-D', 'warnings'],
    ])
      if (await daemonHostCargo(repo, runner, command, check: false) != 0)
        failures.add('cargo ${command.first}');
    if (await runner.run(
          dart,
          [
            if (File(repo.path('.dart_tool/package_config.json')).existsSync())
              '--packages=${repo.path('.dart_tool/package_config.json')}',
            'analyze',
          ],
          workingDirectory: repo.path('daemon'),
          check: false,
        ) !=
        0)
      failures.add('Dart analysis');
    if (failures.isNotEmpty)
      throw BuildFailure('Daemon checks failed: ${failures.join(', ')}');
    return 0;
  }
  if (action != 'deploy' || args.any((arg) => arg != '--dry-run'))
    throw BuildFailure(
      'Expected daemon deploy [--dry-run], check, or clean',
      2,
    );
  final transport = deviceTransport(config);
  try {
    await deployDaemonBundle(
      repo,
      config,
      runner,
      transport,
      dryRun: args.contains('--dry-run'),
    );
  } finally {
    await transport.cancel();
  }
  return 0;
}

/// Stages and checks the complete native-assets bundle before service mutation.
/// A failed startup restores the previous runtime, symlink, units and drop-ins.
Future<void> deployDaemonBundle(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  DeviceTransport device, {
  bool dryRun = false,
}) async {
  final bundle = await verifyDaemonBundle(
    repo.path('build/os/daemon/arm/bundle'),
  );
  final generated = daemonServiceDropins(config);
  for (final name in [
    'tempod.service',
    'tempod-native.service',
    'tempod.socket',
  ])
    generated['/etc/systemd/system/$name'] = File(
      repo.path('daemon/systemd/$name'),
    ).readAsStringSync();
  final listen = RegExp(
    r'^ListenStream=(.*)$',
    multiLine: true,
  ).firstMatch(generated['/etc/systemd/system/tempod.socket']!);
  if (listen?[1]?.trim() != config.string('daemon.socket'))
    throw BuildFailure('tempod.socket and daemon.socket disagree');
  if (dryRun) {
    stdout.writeln(
      'Verified complete ARM daemon bundle (${bundle.files.length} files). Would stage, verify remote hashes, then restart tempod with rollback on failure.',
    );
    return;
  }
  final operations = LiveDeviceOperations(device);
  await operations.check();
  final id = '$pid-${DateTime.now().microsecondsSinceEpoch}',
      stage =
          '/usr/local/lib/tempod.stage-$pid-${DateTime.now().microsecondsSinceEpoch}',
      lock = '/run/lock/tempo-daemon-deploy.lock';
  final remote = '/tmp/tempo-daemon-$id.tar',
      local = Directory.systemTemp.createTempSync('tempo-daemon-deploy-');
  final archive = File(p.join(local.path, 'deployment.tar'));
  final units = <String, String>{};
  final existed = <String, bool>{};
  final active = <String, bool>{};
  bool locked = false, stopped = false, successful = false, recovered = false;
  Future<bool> exists(String path) async =>
      (await device.shell(
        'if [ -e ${quoteRemote(path)} ] || [ -L ${quoteRemote(path)} ]; then printf present; fi',
        root: true,
      )) ==
      'present';
  Future<bool> isActive(String service) async =>
      (await device.shell(
        'if systemctl is-active --quiet ${quoteRemote(service)}; then printf active; fi',
        root: true,
      )) ==
      'active';
  Future<void> restore() async {
    for (final service in [
      'tempo.service',
      'tempod.service',
      'tempod-native.service',
      'tempod.socket',
    ])
      try {
        await device.command(['systemctl', 'stop', service], root: true);
      } on Object {
        /* Continue restoring filesystem even after stop failure. */
      }
    if (await exists('$stage/old-runtime')) {
      await device.command(['rm', '-rf', '/usr/local/lib/tempod'], root: true);
      await device.command([
        'mv',
        '$stage/old-runtime',
        '/usr/local/lib/tempod',
      ], root: true);
    } else if (existed['/usr/local/lib/tempod'] == false) {
      await device.command(['rm', '-rf', '/usr/local/lib/tempod'], root: true);
    }
    for (final entry in units.entries) {
      if (existed[entry.key] == true) {
        await device.command(['rm', '-f', entry.key], root: true);
        await device.command([
          'cp',
          '-a',
          '$stage/backup/${entry.value}',
          entry.key,
        ], root: true);
      } else {
        await device.command(['rm', '-f', entry.key], root: true);
      }
    }
    if (existed['/usr/local/sbin/tempod'] == true) {
      await device.command(['rm', '-f', '/usr/local/sbin/tempod'], root: true);
      await device.command([
        'cp',
        '-a',
        '$stage/backup/entrypoint',
        '/usr/local/sbin/tempod',
      ], root: true);
    } else {
      await device.command(['rm', '-f', '/usr/local/sbin/tempod'], root: true);
    }
    await device.command(['systemctl', 'daemon-reload'], root: true);
    for (final service in [
      'tempod.socket',
      'tempod-native.service',
      'tempod.service',
      'tempo.service',
    ])
      if (active[service] == true)
        await device.command(['systemctl', 'start', service], root: true);
    recovered = true;
  }

  try {
    final runtime = Directory(p.join(local.path, 'runtime'))..createSync();
    for (final entry in bundle.files.entries) {
      final file = File(p.join(runtime.path, entry.key));
      file.parent.createSync(recursive: true);
      File(p.join(bundle.directory, entry.key)).copySync(file.path);
    }
    File(
      p.join(bundle.directory, 'manifest.json'),
    ).copySync(p.join(runtime.path, 'manifest.json'));
    for (final entry in generated.entries) {
      final name = 'unit-${units.length}';
      units[entry.key] = name;
      final file = File(p.join(local.path, 'units', name));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    await runner.run('tar', [
      '-C',
      local.path,
      '-cf',
      archive.path,
      'runtime',
      'units',
    ]);
    await device.command([
      'mkdir',
      '-p',
      '/run/lock',
      '/usr/local/lib',
    ], root: true);
    await device.command(['mkdir', lock], root: true);
    locked = true;
    await device.upload(archive, remote);
    if (await operations.checksum(remote) !=
        (await sha256.bind(archive.openRead()).first).toString())
      throw BuildFailure(
        'Daemon archive transfer checksum mismatch; services unchanged',
      );
    await device.command(['mkdir', '-m', '755', stage], root: true);
    await device.command([
      'tar',
      '--no-same-owner',
      '-C',
      stage,
      '-xf',
      remote,
    ], root: true);
    for (final entry in bundle.files.entries)
      if (await operations.checksum('$stage/runtime/${entry.key}') !=
          entry.value)
        throw BuildFailure(
          'Staged daemon checksum mismatch: ${entry.key}; services unchanged',
        );
    for (final entry in units.entries)
      if (await operations.checksum('$stage/units/${entry.value}') !=
          sha256.convert(utf8.encode(generated[entry.key]!)).toString())
        throw BuildFailure(
          'Staged daemon unit checksum mismatch; services unchanged',
        );
    await device.command([
      'chmod',
      '-R',
      'u=rwX,go=rX',
      '$stage/runtime',
    ], root: true);
    await device.command([
      'chmod',
      '755',
      '$stage/runtime/bin/tempod',
      '$stage/runtime/bin/tempod-native',
    ], root: true);
    await device.command(['mkdir', '$stage/backup'], root: true);
    for (final path in [
      '/usr/local/lib/tempod',
      '/usr/local/sbin/tempod',
      ...units.keys,
    ])
      existed[path] = await exists(path);
    for (final entry in units.entries)
      if (existed[entry.key] == true)
        await device.command([
          'cp',
          '-a',
          entry.key,
          '$stage/backup/${entry.value}',
        ], root: true);
    if (existed['/usr/local/sbin/tempod'] == true)
      await device.command([
        'cp',
        '-a',
        '/usr/local/sbin/tempod',
        '$stage/backup/entrypoint',
      ], root: true);
    for (final service in [
      'tempo.service',
      'tempod.service',
      'tempod-native.service',
      'tempod.socket',
    ])
      active[service] = await isActive(service);
    stopped = true;
    if (active['tempo.service'] == true)
      await device.command(['systemctl', 'stop', 'tempo.service'], root: true);
    await device.command([
      'systemctl',
      'stop',
      'tempod.service',
      if (existed['/etc/systemd/system/tempod-native.service'] == true)
        'tempod-native.service',
      'tempod.socket',
    ], root: true);
    if (existed['/usr/local/lib/tempod'] == true)
      await device.command([
        'mv',
        '/usr/local/lib/tempod',
        '$stage/old-runtime',
      ], root: true);
    await device.command([
      'mv',
      '$stage/runtime',
      '/usr/local/lib/tempod',
    ], root: true);
    await device.command(['mkdir', '-p', '/usr/local/sbin'], root: true);
    await device.command([
      'ln',
      '-sfn',
      '../lib/tempod/bin/tempod',
      '/usr/local/sbin/tempod',
    ], root: true);
    for (final entry in units.entries)
      await device.command([
        'install',
        '-D',
        '-m',
        '644',
        '-o',
        '0',
        '-g',
        '0',
        '$stage/units/${entry.value}',
        entry.key,
      ], root: true);
    await device.command(['systemctl', 'daemon-reload'], root: true);
    await device.command([
      'systemctl',
      'start',
      'tempod.socket',
      'tempod-native.service',
      'tempod.service',
    ], root: true);
    await device.command([
      'systemctl',
      'is-active',
      '--quiet',
      'tempod.socket',
      'tempod-native.service',
      'tempod.service',
    ], root: true);
    // Credentials stay off argv and logs: curl reads its auth header on stdin.
    await device.shell(
      r'''printf 'header = "Authorization: Bearer %s"\n' "$(cat /var/lib/tempod/credentials/api-token)" | curl --connect-timeout 3 --max-time 15 --fail --silent --show-error --output /dev/null --config - http://127.0.0.1:8765/api/v1/player''',
      root: true,
    );
    if (active['tempo.service'] == true) {
      await device.command(['systemctl', 'start', 'tempo.service'], root: true);
      await device.command([
        'systemctl',
        'is-active',
        '--quiet',
        'tempo.service',
      ], root: true);
    }
    await device.command([
      'systemctl',
      'enable',
      'tempod.socket',
      'tempod-native.service',
      'tempod.service',
    ], root: true);
    successful = true;
    stdout.writeln('Complete daemon bundle deployed and services verified.');
  } catch (error) {
    if (stopped) {
      try {
        await restore();
      } catch (rollbackError) {
        throw BuildFailure(
          'Daemon deployment failed: $error. Automatic recovery failed: $rollbackError. Previous runtime and units are retained at $stage; do not delete it.',
        );
      }
      throw BuildFailure(
        'Daemon deployment failed: $error. Previous runtime, units and active services restored.',
      );
    }
    rethrow;
  } finally {
    local.deleteSync(recursive: true);
    try {
      await device.command(['rm', '-f', remote]);
    } on Object {
      /* remote unavailable */
    }
    if (!stopped || successful || recovered)
      try {
        await device.command(['rm', '-rf', stage], root: true);
      } on Object {
        /* safe leftover stage */
      }
    if (locked)
      try {
        await device.command(['rmdir', lock], root: true);
      } on Object {
        /* another deploy must inspect a leftover lock */
      }
  }
}
