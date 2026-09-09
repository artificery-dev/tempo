import 'dart:convert';
import 'dart:io';
import 'package:tempo_build/tempo_build.dart';
import 'package:tempo_build/src/emulator.dart';
import 'package:test/test.dart';

class EmulatorRunner extends CommandRunner {
  EmulatorRunner(this.cache);
  final String cache;
  List<String>? last;
  Map<String, String>? env;
  @override
  Future<ProcessResult> capture(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool check = true,
  }) async => ProcessResult(
    0,
    0,
    jsonEncode({
      'context': {
        'config': {'cachePath': cache},
      },
    }),
    '',
  );
  @override
  Future<int> run(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    Stream<List<int>>? input,
    bool check = true,
  }) async {
    last = [executable, ...args];
    env = environment;
    return 0;
  }
}

void main() {
  test(
    'commit-pinned Toolbox SDK is discovered and emulator uses mock launch flag',
    () async {
      final root = Directory.systemTemp.createTempSync('emulator-tool-test');
      addTearDown(() => root.deleteSync(recursive: true));
      final repo = Repository(root.path),
          runner = EmulatorRunner('${root.path}/cache');
      const revision = '0123456789012345678901234567890123456789';
      final sdk = '${runner.cache}/versions/$revision';
      File(
        '$sdk/bin/${Platform.isWindows ? 'flutter.bat' : 'flutter'}',
      ).parent.createSync(recursive: true);
      File(
        '$sdk/bin/${Platform.isWindows ? 'flutter.bat' : 'flutter'}',
      ).writeAsStringSync('fixture');
      final metadata = File('$sdk/bin/cache/flutter.version.json');
      metadata.parent.createSync();
      metadata.writeAsStringSync(
        jsonEncode({
          'frameworkVersion': '3.44.0',
          'frameworkRevision': revision,
        }),
      );
      final pin = File(repo.path('toolbox/app/.fvmrc'));
      pin.parent.createSync(recursive: true);
      pin.writeAsStringSync(jsonEncode({'flutter': revision}));
      final config = BuildConfig(repo, {
        'flutter': {'sdk_version': 'device-pin'},
      });
      await emulatorCommand(repo, config, runner, 'run', ['-d', 'phone-id']);
      expect(runner.last, containsAllInOrder(['run', '-d', 'phone-id']));
      expect(runner.last!.where((v) => v == '-d'), hasLength(1));
      expect(runner.env, {'TEMPO_TOOLBOX_EMULATOR': '1'});
      expect(
        runner.last,
        contains('--dart-define=TEMPO_TOOLBOX_EMULATOR=true'),
      );
      expect(runner.last!.first, startsWith(sdk));
      await emulatorCommand(repo, config, runner, 'mcp', []);
      expect(
        runner.last!.last,
        repo.path('toolbox/tool/emulator/emulator_mcp.dart'),
      );
    },
  );
  test('developer area help requires neither a checkout nor SDK', () async {
    expect(
      await runDeveloperCommand([
        '--repo',
        '/definitely-not-a-checkout',
        'emulator',
        '--help',
      ]),
      0,
    );
  });
}
