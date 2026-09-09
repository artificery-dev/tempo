import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:tempo_build/tempo_build.dart';
import 'package:toolbox_core/live_device.dart';
import 'package:test/test.dart';

class FakeDevice implements DeviceTransport {
  final events = <String>[];
  final hashes = <String, String>{};
  bool nativeUnitExists = true;
  bool corrupt = false,
      failStartup = false,
      failRecovery = false,
      failed = false;
  @override
  Future<String> command(List<String> args, {bool root = false}) async {
    events.add(args.join(' '));
    if (!nativeUnitExists &&
        args.take(2).join(' ') == 'systemctl stop' &&
        args.contains('tempod-native.service')) {
      throw StateError('Native unit not loaded');
    }
    if (args.first == 'sha256sum') {
      final path = args.last;
      if (corrupt && path.contains('/runtime/')) return '${'0' * 64}  $path';
      final key = path.contains('/runtime/')
          ? 'runtime/${path.split('/runtime/').last}'
          : path.contains('/units/')
          ? 'units/${path.split('/units/').last}'
          : path;
      return '${hashes[key]}  $path';
    }
    if (args.join(' ') ==
            'systemctl start tempod.socket tempod-native.service tempod.service' &&
        failStartup &&
        !failed) {
      failed = true;
      throw StateError('startup failure');
    }
    if (failRecovery && args.first == 'mv' && args[1].endsWith('/old-runtime'))
      throw StateError('recovery failure');
    return '';
  }

  @override
  Future<String> shell(String command, {bool root = false}) async {
    events.add(command);
    if (!nativeUnitExists && command.contains('tempod-native.service'))
      return '';
    return command.startsWith('if [ -e')
        ? 'present'
        : command.startsWith('if systemctl')
        ? 'active'
        : '';
  }

  @override
  Future<void> upload(
    File source,
    String destination, {
    bool root = false,
  }) async {
    hashes[destination] = sha256.convert(source.readAsBytesSync()).toString();
    final temp = Directory.systemTemp.createTempSync('daemon-tar-test');
    try {
      expect(
        (await Process.run('tar', [
          '-C',
          temp.path,
          '-xf',
          source.path,
        ])).exitCode,
        0,
      );
      for (final file in temp.listSync(recursive: true).whereType<File>()) {
        hashes[file.path.substring(temp.path.length + 1)] = sha256
            .convert(file.readAsBytesSync())
            .toString();
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  @override
  Future<void> cancel() async {}
  @override
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  }) => throw UnimplementedError();
}

void main() {
  late Directory root;
  late Repository repo;
  late BuildConfig config;
  late String bundle;
  late Map<String, dynamic> manifest;
  void save() =>
      File('$bundle/manifest.json').writeAsStringSync(jsonEncode(manifest));
  setUp(() {
    root = Directory.systemTemp.createTempSync('daemon-test');
    repo = Repository(root.path);
    config = BuildConfig(repo, {
      'user': {'name': 'tempo'},
      'daemon': {'socket': '/run/tempod/tempod.sock'},
    });
    bundle = '${root.path}/build/os/daemon/arm/bundle';
    final header = Uint8List(20)..setAll(0, [127, 69, 76, 70, 1, 1]);
    header[18] = 40;
    final files = <String, String>{};
    for (final name in [
      'bin/tempod',
      'bin/tempod-native',
      'lib/libsqlite3.so',
      'lib/libtempod_native.so',
    ]) {
      final file = File('$bundle/$name');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(header);
      files[name] = sha256.convert(header).toString();
    }
    manifest = {'target': 'arm', 'native': true, 'files': files};
    save();
    Directory('${root.path}/daemon/systemd').createSync(recursive: true);
    File(
      '${root.path}/daemon/systemd/tempod.socket',
    ).writeAsStringSync('[Socket]\nListenStream=/run/tempod/tempod.sock\n');
    File(
      '${root.path}/daemon/systemd/tempod.service',
    ).writeAsStringSync('[Service]\nType=notify\n');
    File(
      '${root.path}/daemon/systemd/tempod-native.service',
    ).writeAsStringSync('[Service]\nType=exec\n');
  });
  tearDown(() => root.deleteSync(recursive: true));
  test('upgrades a device without a previous native service', () async {
    final device = FakeDevice()..nativeUnitExists = false;
    await deployDaemonBundle(repo, config, CommandRunner(), device);
    expect(
      device.events,
      contains(
        'systemctl start tempod.socket tempod-native.service tempod.service',
      ),
    );
    expect(
      device.events.where(
        (e) =>
            e.startsWith('systemctl stop ') &&
            e.contains('tempod-native.service'),
      ),
      isEmpty,
    );
  });
  test('validates architecture, hashes, missing and extra artifacts', () async {
    expect((await verifyDaemonBundle(bundle)).files.length, 4);
    manifest['target'] = 'x64';
    save();
    await expectLater(verifyDaemonBundle(bundle), throwsA(isA<BuildFailure>()));
    manifest['target'] = 'arm';
    save();
    File('$bundle/extra').writeAsStringSync('stale');
    await expectLater(verifyDaemonBundle(bundle), throwsA(isA<BuildFailure>()));
    File('$bundle/extra').deleteSync();
    File('$bundle/bin/tempod').writeAsStringSync('corrupted');
    await expectLater(verifyDaemonBundle(bundle), throwsA(isA<BuildFailure>()));
    (manifest['files'] as Map).remove('bin/tempod');
    save();
    await expectLater(verifyDaemonBundle(bundle), throwsA(isA<BuildFailure>()));
  });
  test(
    'dry run does not contact device; settings preserve existing path',
    () async {
      final device = FakeDevice();
      await deployDaemonBundle(
        repo,
        config,
        CommandRunner(),
        device,
        dryRun: true,
      );
      expect(device.events, isEmpty);
      expect(
        daemonServiceDropins(config).values.join(),
        contains('TEMPOD_PROFILE_HOME=/home/tempo'),
      );
      expect(
        daemonServiceDropins(config).values.join(),
        contains('TEMPOD_SD_ROOT=/mnt/sd'),
      );
      expect(
        daemonServiceDropins(config).values.join(),
        contains(
          'TEMPOD_SETTINGS_FILE=/home/tempo/.config/tempo/settings.json',
        ),
      );
    },
  );
  test('staging corruption leaves services running', () async {
    final device = FakeDevice()..corrupt = true;
    await expectLater(
      deployDaemonBundle(repo, config, CommandRunner(), device),
      throwsA(isA<BuildFailure>()),
    );
    expect(device.events.where((e) => e.startsWith('systemctl stop')), isEmpty);
  });
  test('startup failure rolls back prior runtime and services', () async {
    final device = FakeDevice()..failStartup = true;
    await expectLater(
      deployDaemonBundle(repo, config, CommandRunner(), device),
      throwsA(isA<BuildFailure>()),
    );
    expect(
      device.events.any(
        (e) =>
            e.startsWith('mv ') &&
            e.contains('/old-runtime /usr/local/lib/tempod'),
      ),
      true,
    );
    expect(
      device.events,
      containsAllInOrder([
        'systemctl daemon-reload',
        'systemctl start tempod.socket',
        'systemctl start tempod.service',
        'systemctl start tempo.service',
      ]),
    );
    expect(
      device.events.where((e) => e.startsWith('systemctl enable')),
      isEmpty,
    );
  });
  test('failed rollback preserves backup for manual recovery', () async {
    final device = FakeDevice()
      ..failStartup = true
      ..failRecovery = true;
    await expectLater(
      deployDaemonBundle(repo, config, CommandRunner(), device),
      throwsA(
        isA<BuildFailure>().having(
          (e) => e.toString(),
          'message',
          contains('Previous runtime and units are retained'),
        ),
      ),
    );
    expect(
      device.events.where(
        (e) => e.startsWith('rm -rf /usr/local/lib/tempod.stage-'),
      ),
      isEmpty,
    );
  });
  test('all hashes verified before service stop', () async {
    final device = FakeDevice();
    await deployDaemonBundle(repo, config, CommandRunner(), device);
    expect(
      device.events.lastIndexWhere((e) => e.startsWith('sha256sum')),
      lessThan(device.events.indexWhere((e) => e.startsWith('systemctl stop'))),
    );
    expect(device.events.any((e) => e.contains('/api/v1/player')), true);
    expect(device.events.last, 'rmdir /run/lock/tempo-daemon-deploy.lock');
  });
}
