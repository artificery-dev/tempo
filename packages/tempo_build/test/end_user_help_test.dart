import 'dart:convert';
import 'dart:io';

import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'end-user help never needs an engine, player or repository working directory',
    () async {
      final root = Repository.locate();
      final temp = Directory.systemTemp.createTempSync('end-user-help-');
      addTearDown(() => temp.deleteSync(recursive: true));
      Future<ProcessResult> invoke(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        [root.path('toolbox/cli/bin/toolbox.dart'), ...args],
        workingDirectory: temp.path,
        environment: {
          'PATH': '${temp.path}/no-tools',
          'TEMPO_USB_ENGINE': '${temp.path}/missing-helper',
          'TEMPO_USB_AGENT': '${temp.path}/missing-agent',
        },
      );
      for (final command in [
        'device',
        'partitions',
        'fetch',
        'backup',
        'restore',
        'install',
        'inspect',
        'inspect-raw',
        'install-raw',
        'doctor',
        'diagnose',
      ]) {
        final result = await invoke([command, '--help']);
        expect(
          result.exitCode,
          0,
          reason: '$command: ${result.stderr} ${result.stdout}',
        );
        expect(result.stdout, contains('Usage: toolbox'), reason: command);
        expect(result.stderr, isEmpty, reason: command);
      }
      final usbHelp = await invoke(['diagnose', '--usb', '-h']);
      expect(usbHelp.exitCode, 0);
      expect(usbHelp.stdout, contains('boot mode'));
      final bad = await invoke(['--json', 'unknown-command', '--help']);
      expect(bad.exitCode, 64);
      expect(jsonDecode(bad.stdout as String)['event'], 'error');
      expect(
        temp.listSync(),
        isEmpty,
        reason: 'Help must not create a backup named --help.',
      );
    },
    // Each invocation JIT-compiles the CLI; a CI host running several jobs
    // takes a good deal longer over the eleven of them than a workstation.
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
