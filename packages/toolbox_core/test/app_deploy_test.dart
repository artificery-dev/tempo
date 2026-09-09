import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:toolbox_core/live_device.dart';
import 'package:test/test.dart';

class AppDevice implements DeviceTransport {
  final events = <String>[];
  String archiveHash = '';
  bool corruptArchive = false,
      corruptStage = false,
      disconnect = false,
      failStart = false,
      failRecovery = false,
      oldDebug = false;
  bool failed = false;
  @override
  Future<String> command(List<String> args, {bool root = false}) async {
    events.add(args.join(' '));
    if (args.first == 'sha256sum')
      return '${corruptArchive ? '0' * 64 : archiveHash}  ${args.last}';
    if (failRecovery && args.first == 'mv' && args[3].contains('.backup-'))
      throw StateError('recovery connection lost');
    return '';
  }

  @override
  Future<String> shell(String command, {bool root = false}) async {
    events.add(command);
    if (command.contains('sha256sum --strict')) {
      if (corruptStage) throw StateError('extracted file corrupt');
      return '';
    }
    if (command.startsWith('if [ -e')) return 'present';
    if (command.startsWith('if systemctl')) return oldDebug ? '' : 'active';
    if (command.startsWith('if pgrep')) return oldDebug ? 'running' : '';
    if (command.endsWith('pgrep -ax flutter-pi') && failStart && !failed) {
      failed = true;
      throw StateError('new app crashed');
    }
    return '';
  }

  @override
  Future<void> upload(
    File source,
    String destination, {
    bool root = false,
  }) async {
    events.add('upload $destination');
    if (disconnect) throw StateError('connection lost');
    archiveHash = sha256.convert(source.readAsBytesSync()).toString();
    final temp = Directory.systemTemp.createTempSync('app-tar-test');
    try {
      expect(
        (await Process.run('tar', [
          '-C',
          temp.path,
          '-xzf',
          source.path,
        ])).exitCode,
        0,
      );
      final manifest = File(
        '${temp.path}/.tempo-deploy.sha256',
      ).readAsLinesSync();
      expect(manifest, isNotEmpty);
      for (final line in manifest) {
        expect(
          sha256
              .convert(
                File('${temp.path}/${line.substring(66)}').readAsBytesSync(),
              )
              .toString(),
          line.substring(0, 64),
        );
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  @override
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  }) => throw UnimplementedError();
  @override
  Future<void> cancel() async {}
}

class CancelledDeployment implements DeviceTransport {
  CancelledDeployment(this.device, {required this.duringUpload});
  final AppDevice device;
  final bool duringUpload;
  bool cancelled = false;
  void check() {
    if (cancelled) throw DeviceOperationFailure('Device operation cancelled');
  }

  @override
  Future<String> command(List<String> args, {bool root = false}) async {
    check();
    final result = await device.command(args, root: root);
    if (!duringUpload && args.first == 'mv' && args[3].contains('.stage-')) {
      await cancel();
      check();
    }
    return result;
  }

  @override
  Future<String> shell(String command, {bool root = false}) {
    check();
    return device.shell(command, root: root);
  }

  @override
  Future<void> upload(
    File source,
    String destination, {
    bool root = false,
  }) async {
    check();
    await device.upload(source, destination, root: root);
    if (duringUpload) {
      await cancel();
      check();
    }
  }

  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  }) => throw UnimplementedError();
}

void main() {
  late Directory bundle;
  late AppDevice device;
  setUp(() {
    bundle = Directory.systemTemp.createTempSync('app-bundle-test');
    File('${bundle.path}/app.so').writeAsStringSync('release');
    File('${bundle.path}/asset with spaces').writeAsStringSync('asset');
    device = AppDevice();
  });
  tearDown(() => bundle.deleteSync(recursive: true));
  Future<void> deploy({bool release = true}) =>
      LiveDeviceOperations(device).deployBundle(
        bundle,
        release: release,
        destination: '/opt/tempo/flutter_assets/',
        flutterPi: '/usr/bin/flutter-pi',
        engineDirectory: '/usr/lib',
        pixelFormat: 'RGB565',
        vmServicePort: 41200,
        startupWait: Duration.zero,
      );
  for (final fault in ['archive', 'stage', 'disconnect']) {
    test('$fault failure leaves live files and services untouched', () async {
      device.corruptArchive = fault == 'archive';
      device.corruptStage = fault == 'stage';
      device.disconnect = fault == 'disconnect';
      await expectLater(deploy(), throwsA(anything));
      expect(
        device.events.where((e) => e.startsWith('systemctl stop')),
        isEmpty,
      );
      expect(device.events.where((e) => e.startsWith('mv ')), isEmpty);
      expect(
        device.events.where((e) => e == 'rm -rf -- /opt/tempo/flutter_assets'),
        isEmpty,
      );
    });
  }
  test(
    'verified stage precedes stopping; new bundle moves into place',
    () async {
      await deploy();
      expect(
        device.events.indexWhere((e) => e.contains('sha256sum --strict')),
        lessThan(device.events.indexOf('systemctl stop tempo.service')),
      );
      expect(
        device.events.any(
          (e) =>
              e.startsWith('mv -T -- /opt/tempo/flutter_assets.stage-') &&
              e.endsWith(' /opt/tempo/flutter_assets'),
        ),
        true,
      );
      expect(
        device.events.any(
          (e) => e.startsWith('rm -rf -- /opt/tempo/flutter_assets.backup-'),
        ),
        true,
      );
    },
  );
  test('startup failure restores prior bundle and active service', () async {
    device.failStart = true;
    await expectLater(deploy(), throwsA(isA<DeviceOperationFailure>()));
    expect(
      device.events.any(
        (e) => e.startsWith('mv -T -- /opt/tempo/flutter_assets.backup-'),
      ),
      true,
    );
    expect(
      device.events.where((e) => e == 'systemctl start tempo.service'),
      hasLength(2),
    );
  });
  test('failed recovery preserves backup and debug launch evidence', () async {
    device.failStart = true;
    device.failRecovery = true;
    await expectLater(
      deploy(),
      throwsA(
        isA<DeviceOperationFailure>().having(
          (e) => e.message,
          'message',
          contains('Retain'),
        ),
      ),
    );
    expect(
      device.events.any(
        (e) => e.startsWith('rm -rf -- /opt/tempo/flutter_assets.backup-'),
      ),
      false,
    );
    expect(
      device.events.any(
        (e) => e.startsWith('rm -f -- ') && e.endsWith('.cmdline'),
      ),
      false,
    );
  });
  test(
    'debug startup retains VM flags and rollback relaunches original argv',
    () async {
      File('${bundle.path}/app.so').deleteSync();
      device.oldDebug = true;
      device.failStart = true;
      await expectLater(
        deploy(release: false),
        throwsA(isA<DeviceOperationFailure>()),
      );
      expect(
        device.events.any(
          (e) =>
              e.contains('--vm-service-port=41200') &&
              e.contains('--disable-service-auth-codes'),
        ),
        true,
      );
      expect(
        device.events.any(
          (e) => e.startsWith('xargs -0 -a ') && e.contains(' setsid '),
        ),
        true,
      );
      expect(
        device.events.where((e) => e == 'systemctl start tempo.service'),
        isEmpty,
      );
    },
  );
  for (final duringUpload in [true, false]) {
    test(
      'cancel ${duringUpload ? 'during upload' : 'after replacement'} uses independent cleanup connection',
      () async {
        final forward = CancelledDeployment(device, duringUpload: duringUpload);
        var recoveries = 0;
        await expectLater(
          LiveDeviceOperations(
            forward,
            recoveryTransportFactory: () {
              recoveries++;
              return device;
            },
          ).deployBundle(
            bundle,
            release: true,
            destination: '/opt/tempo/flutter_assets',
            flutterPi: '/usr/bin/flutter-pi',
            engineDirectory: '/usr/lib',
            pixelFormat: 'RGB565',
            vmServicePort: 41200,
            startupWait: Duration.zero,
          ),
          throwsA(isA<DeviceOperationFailure>()),
        );
        expect(forward.cancelled, true);
        expect(recoveries, 1);
        expect(
          device.events,
          contains('rmdir -- /opt/tempo/flutter_assets.deploy-lock'),
        );
        final starts = device.events.where(
          (event) => event == 'systemctl start tempo.service',
        );
        expect(starts, hasLength(duringUpload ? 0 : 1));
        expect(
          device.events.any(
            (event) =>
                event.startsWith('mv -T -- /opt/tempo/flutter_assets.backup-'),
          ),
          !duringUpload,
        );
        // Forward adapter remains cancelled; cleanup never resumes the install.
        await expectLater(
          forward.command(['true']),
          throwsA(isA<DeviceOperationFailure>()),
        );
      },
    );
  }
}
