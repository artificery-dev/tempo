import 'dart:async';
import 'dart:io';

import 'package:toolbox_core/live_device.dart';
import 'package:toolbox_core/support_diagnostics.dart';
import 'package:test/test.dart';

class SupportDevice implements DeviceTransport {
  bool inactive = false, unreachable = false, stall = false, cancelled = false;
  final calls = <List<String>>[];
  final pending = Completer<String>();
  String daemonPid = '202';
  @override
  Future<String> command(List<String> arguments, {bool root = false}) async {
    expect(root, false);
    calls.add(arguments);
    if (unreachable) throw DeviceOperationFailure('Connection refused');
    if (stall) return pending.future;
    if (arguments.first == 'systemctl') {
      return ['tempo.service', 'tempod.service', 'tempod-native.service']
          .map(
            (name) =>
                'Id=$name\nActiveState=${inactive && name == 'tempod.service' ? 'failed' : 'active'}\nMainPID=${name == 'tempod.service'
                    ? daemonPid
                    : name == 'tempo.service'
                    ? '101'
                    : '303'}',
          )
          .join('\n\n');
    }
    if (arguments.first == 'ps') {
      return '101 flutter-pi 3.0 50000\n202 dart:tempod.dart 1.0 30000\n303 tempod-native 0.5 9000';
    }
    return 'fixture reading';
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!pending.isCompleted)
      pending.completeError(DeviceOperationFailure('Cancelled'));
  }

  @override
  Future<String> shell(String command, {bool root = false}) =>
      throw StateError('No shell commands');
  @override
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  }) => throw StateError('No raw device reads');
  @override
  Future<void> upload(File source, String destination, {bool root = false}) =>
      throw StateError('No device writes');
}

void main() {
  test(
    'service MainPIDs include Dart runtime without exposing command lines',
    () async {
      final device = SupportDevice();
      final report = await SupportDiagnostics(device).collect();
      expect(report['healthy'], true);
      expect(device.calls.last, [
        'ps',
        '-o',
        'pid=,comm=,pcpu=,rss=',
        '-p',
        '101,202,303',
      ]);
      final process = (report['checks'] as List).cast<Map>().singleWhere(
        (check) => check['name'] == 'player-processes',
      );
      expect(process['output'], contains('202 dart:tempod.dart 1.0 30000'));
      expect(device.calls.last.join(' '), isNot(contains('args')));
    },
  );
  test('invalid active MainPID is reported and never passed to ps', () async {
    for (final invalid in ['0', 'not-a-pid', '202,999', '-1']) {
      final device = SupportDevice()..daemonPid = invalid;
      final report = await SupportDiagnostics(device).collect();
      expect(report['healthy'], false);
      expect(device.calls.last.last, '101,303');
      final service = (report['checks'] as List).cast<Map>().singleWhere(
        (check) => check['name'] == 'player-services',
      );
      expect(
        service['issues'],
        contains('tempod.service has no valid MainPID'),
      );
    }
  });
  test(
    'curated checks use read-only unprivileged commands and identify stopped services',
    () async {
      final device = SupportDevice();
      var report = await SupportDiagnostics(device).collect();
      expect(report['healthy'], true);
      expect((report['checks'] as List), hasLength(7));
      expect(
        device.calls.expand((call) => call).join(' '),
        isNot(contains('journal')),
      );
      device.inactive = true;
      report = await SupportDiagnostics(device).collect();
      expect(report['complete'], true);
      expect(report['healthy'], false);
      final service = (report['checks'] as List).cast<Map>().singleWhere(
        (check) => check['name'] == 'player-services',
      );
      expect(service['issues'], ['tempod.service is not active']);
    },
  );
  test(
    'unreachable device returns one useful failure without repeated retries',
    () async {
      final device = SupportDevice()..unreachable = true;
      final report = await SupportDiagnostics(device).collect();
      expect(report['complete'], false);
      expect(report['healthy'], false);
      expect(device.calls, hasLength(1));
    },
  );
  test('timeout closes the connection and returns a partial report', () async {
    final device = SupportDevice()..stall = true;
    final report = await SupportDiagnostics(
      device,
      timeout: const Duration(milliseconds: 10),
    ).collect();
    expect(device.cancelled, true);
    expect(report['complete'], false);
    expect(report['cancelled'], false);
  });
  test('user cancellation stops subsequent checks', () async {
    final device = SupportDevice()..stall = true;
    final diagnostics = SupportDiagnostics(device);
    final collecting = diagnostics.collect();
    await diagnostics.cancel();
    final report = await collecting;
    expect(report['cancelled'], true);
    expect(report['healthy'], false);
    expect(device.calls, hasLength(1));
  });
  test(
    'SSH endpoints reject option-like and combined account inputs before process start',
    () {
      for (final host in [
        '-oProxyCommand=bad',
        'user@host',
        'host name',
        'host/path',
      ]) {
        expect(
          () => SshDeviceTransport(host: host, user: 'tempo'),
          throwsArgumentError,
        );
      }
      expect(
        () => SshDeviceTransport(host: 'localhost', user: '-oProxyCommand=bad'),
        throwsArgumentError,
      );
      for (final host in [
        '10.42.0.1',
        'titan',
        '::1',
        '[::1]',
        'fe80::1%usb0',
      ]) {
        expect(
          SshDeviceTransport(host: host, user: 'tempo').target,
          'tempo@$host',
        );
      }
    },
  );
}
