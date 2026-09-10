import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:dbus/dbus.dart';
import 'package:daemon_client/daemon_client.dart';

Future<void> main() async {
  final entry = File(
    Directory.current.path.endsWith('/daemon')
        ? 'bin/tempod.dart'
        : 'daemon/bin/tempod.dart',
  ).absolute.path;
  final compiled = Platform.environment['TEMPOD_TEST_EXECUTABLE'];
  final executable = compiled ?? Platform.resolvedExecutable;
  final packageConfig = await Isolate.packageConfig;
  final prefix = compiled == null
      ? [
          if (packageConfig != null) '--packages=${packageConfig.toFilePath()}',
          entry,
        ]
      : <String>[];

  test('help needs neither credentials nor native libraries', () async {
    final result = await Process.run(
      executable,
      [...prefix, '--help'],
      environment: {'TEMPOD_API_TOKEN': ''},
    );
    expect(result.exitCode, 0);
    expect(result.stdout, contains('--native-library'));
  });

  test('missing credentials fail before listening', () async {
    final result = await Process.run(
      executable,
      [...prefix, '--port', '0'],
      environment: {'TEMPOD_API_TOKEN': ''},
    );
    expect(result.exitCode, 64);
    expect(result.stderr, contains('TEMPOD_API_TOKEN'));
    expect(result.stdout, isNot(contains('listening')));
  });

  test('daemon serves requests and releases its listener on SIGTERM', () async {
    final process = await Process.start(
      executable,
      [...prefix, '--demo-player', '--port', '0'],
      environment: {'TEMPOD_API_TOKEN': 'process-test-token'},
    );
    final errors = process.stderr.transform(utf8.decoder).join();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final http = HttpClient();
    try {
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 15)),
        isTrue,
      );
      final base = Uri.parse(
        lines.current.replaceFirst('tempod listening at ', ''),
      );
      final request = await http.getUrl(base.resolve('/api/v1/player'));
      request.headers.set('authorization', 'Bearer process-test-token');
      final response = await request.close();
      expect(response.statusCode, 200);
      final state = jsonDecode(await response.transform(utf8.decoder).join());
      expect(state['available'], isTrue);
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, contains('Demo player enabled'));
      await expectLater(
        Socket.connect('127.0.0.1', base.port),
        throwsA(isA<SocketException>()),
      );
    } finally {
      http.close(force: true);
      process.kill(ProcessSignal.sigkill);
      await lines.cancel();
      await process.exitCode;
    }
  });
  test('SIGTERM closes Bluetooth and its background ports', () async {
    final home = await Directory.systemTemp.createTemp('tempod-shutdown-');
    final bus = DBusServer();
    final address = await bus.listenAddress(DBusAddress.unix(dir: home));
    final process = await Process.start(
      executable,
      [...prefix, '--port', '0', '--bluetooth-player'],
      environment: {
        'TEMPOD_API_TOKEN': 'process-test-token',
        'DBUS_SYSTEM_BUS_ADDRESS': address.toString(),
      },
    );
    final errors = process.stderr.transform(utf8.decoder).join();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 15)),
        isTrue,
      );
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode.timeout(const Duration(seconds: 12)), 0);
      final log = await errors;
      expect(log, contains('shutdown: bluetooth stopped'));
      expect(log, contains('shutdown: cleanup complete'));
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await lines.cancel();
      await bus.close();
      await home.delete(recursive: true);
    }
  });
  test('bare mountpoint cannot become an attached card', () async {
    final root = await Directory.systemTemp.createTemp(
      'tempod-missing-profile-',
    );
    final home = '${root.path}/home';
    final selector = File('$home/.local/state/tempo/storage-selector.json');
    selector.parent.createSync(recursive: true);
    selector.writeAsStringSync('{"version":1,"policy":"yes"}');
    final bareMountpoint = Directory('${root.path}/card/.cadence')
      ..createSync(recursive: true);
    final process = await Process.start(
      executable,
      [...prefix, '--port', '0'],
      environment: {
        'TEMPOD_API_TOKEN': 'process-test-token',
        'TEMPOD_PROFILE_HOME': home,
        'TEMPOD_SD_ROOT': bareMountpoint.parent.path,
      },
    );
    final errors = process.stderr.transform(utf8.decoder).join();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 15)),
        isTrue,
      );
      final base = Uri.parse(
        lines.current.replaceFirst('tempod listening at ', ''),
      );
      final status = await StorageClient(
        baseUri: base,
        token: 'process-test-token',
      ).status();
      expect(
        status.available,
        isTrue,
        reason:
            'Unavailable Cadence must not disable the internal settings profile',
      );
      expect(status.location, 'device');
      expect(
        status.sdAvailable,
        isFalse,
        reason: 'bare directory is not a mounted card',
      );
      expect(status.mediaHome, home);
      expect(status.dataPath, '$home/.cadence');
      final settings = SettingsClient(
        baseUri: base,
        token: 'process-test-token',
      );
      await settings.write({'theme': 'dark'});
      expect(await settings.read(), {'theme': 'dark'});
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      await errors;
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await lines.cancel();
      await root.delete(recursive: true);
    }
  });
  test(
    'invalid settings are reported without modifying the internal file',
    () async {
      final root = Directory.systemTemp.createTempSync('tempod-settings-');
      final target = File('${root.path}/settings.json')
        ..writeAsStringSync('invalid json');
      final process = await Process.start(
        executable,
        [...prefix, '--port', '0', '--settings-file', target.path],
        environment: {'TEMPOD_API_TOKEN': 'process-test-token'},
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          true,
        );
        final base = Uri.parse(
          lines.current.replaceFirst('tempod listening at ', ''),
        );
        await expectLater(
          SettingsClient(baseUri: base, token: 'process-test-token').read(),
          throwsA(isA<HttpException>()),
        );
        expect(target.readAsStringSync(), 'invalid json');
        process.kill(ProcessSignal.sigterm);
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
        await errors;
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        root.deleteSync(recursive: true);
      }
    },
  );
}
