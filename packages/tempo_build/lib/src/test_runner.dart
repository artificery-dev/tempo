import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';

/// Runs package:test directly, preserving the app's Flutter dependency lock,
/// from an isolated package configuration under the daemon's build output.
/// Building the daemon as a CLI bundle first proves it still links as one.
Future<int> runDaemonTests(
  Repository repo,
  CommandRunner runner,
  String dart,
  List<String> args, {
  Map<String, String>? environment,
  bool check = true,
}) async {
  final configFile = File(repo.path('.dart_tool/package_config.json'));
  if (!configFile.existsSync())
    throw BuildFailure('Run workspace get before daemon tests.');
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  Uri? testRoot;
  for (final package in config['packages'] as List) {
    final uri = configFile.uri.resolve(package['rootUri'] as String);
    package['rootUri'] = uri.toString();
    if (package['name'] == 'test') testRoot = uri;
  }
  if (testRoot == null)
    throw BuildFailure('package:test is absent from workspace resolution.');
  final output = repo.path('build/os/daemon/test-runtime');
  final abi = Abi.current().toString();
  final target = abi.endsWith('_arm64')
      ? 'arm64'
      : abi.endsWith('_x64')
      ? 'x64'
      : throw BuildFailure('Unsupported daemon test host $abi');
  await runner.run(dart, [
    'build',
    'cli',
    '--packages=${configFile.path}',
    '--target',
    'bin/tempod.dart',
    '--target-os',
    Platform.operatingSystem,
    '--target-arch',
    target,
    '--output',
    output,
  ], workingDirectory: repo.path('daemon'));
  final isolated = Directory(p.join(output, '.dart_tool'))
    ..createSync(recursive: true);
  final packageConfig = File(p.join(isolated.path, 'package_config.json'))
    ..writeAsStringSync(jsonEncode(config));
  return runner.run(
    dart,
    [
      '--packages=${packageConfig.path}',
      p.join(testRoot.toFilePath(), 'bin', 'test.dart'),
      ...args,
    ],
    workingDirectory: repo.path('daemon'),
    environment: environment,
    check: check,
  );
}
