import 'dart:io';
import 'package:tempo_build/src/developer_help.dart';
import 'package:test/test.dart';

void main() {
  test('every registered command has specific usage and details', () {
    for (final command in developerCommands.keys) {
      final help = developerCommandHelp([...command.split(' '), '--help']);
      expect(help, startsWith('Usage: toolbox dev $command'), reason: command);
      expect(help, contains(developerCommands[command]!.$2), reason: command);
    }
  });
  test('nested groups list only their own actions', () {
    final help = developerCommandHelp(['os', 'rootfs', '--help']);
    expect(help, contains('stage-plymouth TREE OUTPUT'));
    expect(help, contains('shell [--] [COMMAND arguments]'));
    expect(help, isNot(contains('flash-boot')));
    expect(
      developerCommandHelp(['app', 'flutter-pi', '-h']),
      contains('engine'),
    );
  });
  test(
    'unknown groups/actions fail rather than showing unrelated global help',
    () {
      for (final path in [
        ['missing'],
        ['os', 'missing'],
        ['os', 'rootfs', 'missing'],
        ['app', 'flutter-pi', 'missing'],
        ['diagnostics', 'missing'],
      ]) {
        expect(
          () => developerCommandHelp([...path, '--help']),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Unknown developer command'),
            ),
          ),
        );
      }
    },
  );
  test(
    'leaf help tolerates operands and options without treating them as commands',
    () {
      final help = developerCommandHelp([
        'os',
        'kernel',
        'bootimg',
        '--output',
        'my boot.img',
        '-h',
      ]);
      expect(help, contains('--max-size BYTES'));
      expect(help, isNot(contains('--force')));
      expect(
        developerCommandHelp(['daemon', 'build', '--help']),
        contains('Default target: host'),
      );
      expect(
        developerCommandHelp(['diagnostics', 'analyze-tone', '-h']),
        contains('64 invalid input'),
      );
    },
  );
  test(
    'actual dispatcher help and errors work outside a checkout without PATH tools',
    () async {
      final root =
          Directory.current.path.endsWith(
            '${Platform.pathSeparator}packages${Platform.pathSeparator}tempo_build',
          )
          ? Directory.current.parent.parent.path
          : Directory.current.path;
      final packageConfig = File(
        '$root/packages/tempo_build/.dart_tool/package_config.json',
      );
      final fallback = File('$root/.dart_tool/package_config.json');
      final config = packageConfig.existsSync()
          ? packageConfig.path
          : fallback.path;
      final temp = Directory.systemTemp.createTempSync('developer-help-');
      try {
        for (final entry in [
          (['os', 'rootfs', 'stage-plymouth', '--help'], 0, 'TREE OUTPUT'),
          (['diagnostics', 'analyze-tone', '--help'], 0, '--minimum-gap-ms'),
          (['os', 'imaginary', '--help'], 2, 'Unknown developer command'),
          (
            ['app', 'flutter-pi', 'imaginary', '-h'],
            2,
            'Unknown developer command',
          ),
        ]) {
          final result = await Process.run(
            Platform.resolvedExecutable,
            [
              '--packages=$config',
              '$root/packages/tempo_build/bin/tempo_build.dart',
              '--repo',
              '${temp.path}/absent',
              ...entry.$1,
            ],
            workingDirectory: temp.path,
            environment: {'PATH': '${temp.path}/no-tools'},
            includeParentEnvironment: false,
          );
          expect(
            result.exitCode,
            entry.$2,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect('${result.stdout}${result.stderr}', contains(entry.$3));
          expect(
            '${result.stdout}${result.stderr}',
            isNot(contains('Could not locate')),
          );
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    // Four invocations, each compiling the dispatcher from source; a host
    // running several jobs at once takes minutes over that.
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
