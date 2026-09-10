import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';

/// Owns the standalone media daemon's lifetime, without loading its scanner or
/// SQLite into tempod. setpriv execs in place, so the supervised PID is cadenced.
class CadenceProcess {
  CadenceProcess._(this.process, this.client, this._log);
  final Process process;
  final CadenceClient client;
  final void Function(String) _log;
  Future<void>? _closing;
  bool _stopping = false;
  int? _exitCode;
  final List<StreamSubscription<String>> _output = [];

  static Future<CadenceProcess> start({
    required List<String> arguments,
    required String socketPath,
    required String user,
    required int uid,
    required int gid,
    String executable = '/usr/local/lib/cadenced/bin/cadenced',
    Duration timeout = const Duration(seconds: 20),
    required void Function(String) log,
    required void Function(int) onUnexpectedExit,
  }) async {
    final directory = Directory(File(socketPath).parent.path);
    await directory.create(recursive: true);
    final owner = await Process.run('chown', ['$uid:$gid', directory.path]);
    if (owner.exitCode != 0) {
      throw StateError('Cannot assign Cadence socket owner');
    }
    final mode = await Process.run('chmod', ['700', directory.path]);
    if (mode.exitCode != 0) {
      throw StateError('Cannot protect Cadence socket directory');
    }
    final process = await Process.start(
      'setpriv',
      [
        '--reuid=$user',
        '--regid=$gid',
        '--init-groups',
        executable,
        '--socket',
        socketPath,
        ...arguments,
      ],
      environment: {
        'CADENCE_PROBE_PATH':
            '${File(executable).parent.parent.path}/lib/libcadence_probe.so',
      },
    );
    final ownerProcess = CadenceProcess._(
      process,
      CadenceClient(
        UnixMediaTransport(socketPath, timeout: const Duration(seconds: 2)),
      ),
      log,
    );
    ownerProcess._output.addAll([
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(log),
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(log),
    ]);
    unawaited(
      process.exitCode.then((code) {
        ownerProcess._exitCode = code;
        if (!ownerProcess._stopping) onUnexpectedExit(code);
      }),
    );
    try {
      final deadline = DateTime.now().add(timeout);
      Object? lastError;
      while (DateTime.now().isBefore(deadline)) {
        if (ownerProcess._exitCode != null) {
          throw StateError(
            'Cadence exited during startup (${ownerProcess._exitCode})',
          );
        }
        try {
          await ownerProcess.client.volumeStatus();
          return ownerProcess;
        } catch (error) {
          lastError = error;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      throw TimeoutException(
        'Cadence did not open its socket: $lastError',
        timeout,
      );
    } catch (_) {
      await ownerProcess.close();
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _stopping = true;
    await client.close();
    if (_exitCode == null) process.kill(ProcessSignal.sigterm);
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 20));
      if (code != 0) {
        throw StateError('Cadence did not shut down cleanly ($code)');
      }
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      _log(
        'Cadence shutdown timed out; storage must not be moved in this lifetime.',
      );
      rethrow;
    } finally {
      for (final subscription in _output) {
        await subscription.cancel();
      }
    }
  }
}
