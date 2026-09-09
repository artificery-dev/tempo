import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';

/// Runs package:test directly, preserving the app's Flutter dependency lock.
/// The isolated package configuration owns its SQLite JIT asset mapping.
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
  final library = Directory(p.join(output, 'bundle', 'lib'))
      .listSync()
      .whereType<File>()
      .where((file) => p.basename(file.path).contains('sqlite3'))
      .firstOrNull;
  if (library == null)
    throw BuildFailure('Daemon test build omitted SQLite native asset.');
  final isolated = Directory(p.join(output, '.dart_tool'))
    ..createSync(recursive: true);
  final packageConfig = File(p.join(isolated.path, 'package_config.json'))
    ..writeAsStringSync(jsonEncode(config));
  File(p.join(isolated.path, 'native_assets.yaml')).writeAsStringSync(
    jsonEncode({
      'format-version': [1, 0, 0],
      'native-assets': {
        abi: {
          'package:sqlite3/src/ffi/libsqlite3.g.dart': [
            'absolute',
            library.absolute.path,
          ],
        },
      },
    }),
  );
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
