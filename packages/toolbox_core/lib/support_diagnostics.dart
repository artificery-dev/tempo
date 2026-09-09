import 'dart:async';

import 'live_device.dart';

/// Read-only support checks shared by the CLI and desktop Toolbox.
/// Deliberately excludes credentials, settings, media filenames and journals.
class SupportDiagnostics {
  SupportDiagnostics(
    this.transport, {
    this.timeout = const Duration(seconds: 15),
    void Function(String)? onProgress,
  }) : onProgress = onProgress ?? ((_) {});

  final DeviceTransport transport;
  final Duration timeout;
  final void Function(String) onProgress;
  bool _cancelled = false;

  Future<void> cancel() async {
    _cancelled = true;
    await transport.cancel();
  }

  Future<Map<String, Object?>> collect() async {
    final checks = <Map<String, Object?>>[];
    final commands = <String, List<String>>{
      'system': ['uname', '-srmo'],
      'release': ['cat', '/etc/os-release'],
      'uptime': ['cat', '/proc/uptime'],
      'memory': ['cat', '/proc/meminfo'],
      'storage': ['df', '-P', '/'],
      'player-services': [
        'systemctl',
        'show',
        'tempo.service',
        'tempod.service',
        'tempod-native.service',
        '--no-pager',
        '--property=Id,LoadState,ActiveState,SubState,NRestarts,Result,MainPID',
      ],
      'player-processes': ['ps', '-o', 'pid=,comm=,pcpu=,rss='],
    };
    var timedOut = false;
    final playerPids = <int>{};
    for (final entry in commands.entries) {
      if (_cancelled) break;
      onProgress('Checking ${entry.key}');
      try {
        if (entry.key == 'player-processes' && playerPids.isEmpty) {
          throw DeviceOperationFailure('No player service MainPID available.');
        }
        final command = entry.key == 'player-processes'
            ? [...entry.value, '-p', playerPids.join(',')]
            : entry.value;
        final output = await transport.command(command).timeout(timeout);
        if (_cancelled) break;
        final issues = <String>[];
        if (entry.key == 'player-services') {
          final blocks = output.split(RegExp(r'\n\s*\n'));
          for (final service in [
            'tempo.service',
            'tempod.service',
            'tempod-native.service',
          ]) {
            final block = blocks
                .where((block) => block.split('\n').contains('Id=$service'))
                .firstOrNull;
            if (block == null ||
                !block.split('\n').contains('ActiveState=active')) {
              issues.add('$service is not active');
            }
            final pidText = block
                ?.split('\n')
                .where((line) => line.startsWith('MainPID='))
                .firstOrNull
                ?.substring('MainPID='.length);
            final pid = pidText == null ? null : int.tryParse(pidText);
            if (pid != null && pid > 0 && pid <= 0x7fffffff) {
              playerPids.add(pid);
            } else if (block?.split('\n').contains('ActiveState=active') ??
                false) {
              issues.add('$service has no valid MainPID');
            }
          }
        }
        checks.add({
          'name': entry.key,
          'status': issues.isEmpty ? 'ok' : 'attention',
          'output': output,
          if (issues.isNotEmpty) 'issues': issues,
        });
      } on TimeoutException {
        timedOut = true;
        await transport.cancel();
        checks.add({
          'name': entry.key,
          'status': 'error',
          'message':
              'Check exceeded ${timeout.inSeconds} seconds; connection closed.',
        });
        break;
      } catch (error) {
        if (_cancelled) break;
        checks.add({'name': entry.key, 'status': 'error', 'message': '$error'});
        // A failed first check is usually an unreachable player or missing SSH.
        // Do not repeat the same connection timeout for every remaining check.
        if (checks.length == 1) break;
      }
    }
    final complete =
        checks.length == commands.length && !_cancelled && !timedOut;
    return {
      'event': 'diagnostic-report',
      'schema_version': 1,
      'collected_at': DateTime.now().toUtc().toIso8601String(),
      'complete': complete,
      'healthy': complete && checks.every((check) => check['status'] == 'ok'),
      'cancelled': _cancelled,
      'checks': checks,
    };
  }
}
