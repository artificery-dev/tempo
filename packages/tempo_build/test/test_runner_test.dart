import 'dart:convert';
import 'dart:io';
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

class TestRunner extends CommandRunner {
  final calls = <List<String>>[];
  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Stream<List<int>>? input,
    bool check = true,
  }) async {
    calls.add([executable, ...arguments]);
    if (arguments.first == 'build') {
      final output = arguments[arguments.indexOf('--output') + 1];
      final library = File('$output/bundle/lib/libsqlite3.so');
      library.parent.createSync(recursive: true);
      library.writeAsStringSync('fixture');
    }
    return 0;
  }
}

void main() {
  test(
    'native test configuration is isolated and resolves directory URIs without trailing slash',
    () async {
      final root = Directory.systemTemp.createTempSync('test-runner');
      addTearDown(() => root.deleteSync(recursive: true));
      final config = File('${root.path}/.dart_tool/package_config.json');
      config.parent.createSync();
      final original = jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'test',
            'rootUri': '../test-package',
            'packageUri': 'lib/',
            'languageVersion': '3.12',
          },
        ],
      });
      config.writeAsStringSync(original);
      final assets = File('${root.path}/.dart_tool/native_assets.yaml')
        ..writeAsStringSync('existing map');
      final lock = File('${root.path}/pubspec.lock')
        ..writeAsStringSync('app lock');
      final runner = TestRunner();
      await runDaemonTests(Repository(root.path), runner, 'pinned-dart', [
        'test/example_test.dart',
      ]);
      expect(config.readAsStringSync(), original);
      expect(assets.readAsStringSync(), 'existing map');
      expect(lock.readAsStringSync(), 'app lock');
      expect(
        runner.calls.last,
        contains('${root.path}/test-package/bin/test.dart'),
      );
      expect(
        runner.calls.last[1],
        contains(
          '/build/os/daemon/test-runtime/.dart_tool/package_config.json',
        ),
      );
      final isolated = jsonDecode(
        File(
          '${root.path}/build/os/daemon/test-runtime/.dart_tool/native_assets.yaml',
        ).readAsStringSync(),
      );
      expect(isolated['native-assets'], isNotEmpty);
    },
  );
}
