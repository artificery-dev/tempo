import 'dart:convert';
import 'dart:io';
import 'package:tempo_build/tempo_build.dart';
import 'package:tempo_build/src/toolbox_linux.dart';
import 'package:test/test.dart';
import 'toolbox_container_test.dart' show RecordingRunner;

class SdkCopyRunner extends RecordingRunner {
  SdkCopyRunner(this.cache);
  final String cache;
  @override
  Future<ProcessResult> capture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool check = true,
  }) async => executable == 'fvm'
      ? ProcessResult(
          0,
          0,
          jsonEncode({
            'context': {
              'config': {'cachePath': cache},
            },
          }),
          '',
        )
      : ProcessResult(0, 0, '', '');
  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Stream<List<int>>? input,
    bool check = true,
  }) async {
    await super.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
      check: check,
    );
    final index = arguments.indexOf('cp');
    if (index >= 0) {
      final source = Directory(arguments[index + 2]);
      final target = Directory(arguments[index + 3])
        ..createSync(recursive: true);
      for (final entry in source.listSync(
        recursive: true,
        followLinks: false,
      )) {
        final destination =
            '${target.path}${entry.path.substring(source.path.length)}';
        if (entry is Directory)
          Directory(destination).createSync(recursive: true);
        if (entry is File) entry.copySync(destination);
      }
    }
    return 0;
  }
}

void main() {
  // These describe the host's view of the toolchain, even when the suite
  // itself runs inside the container (as in CI).
  setUpAll(() => Toolchain.insideContainer = false);
  tearDownAll(() => Toolchain.insideContainer = null);
  late Directory temporary;
  late Repository repo;
  late RecordingRunner runner;
  late LinuxToolboxBuilder builder;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('linux toolbox test ');
    repo = Repository('${temporary.path}/checkout');
    Directory(repo.root).createSync();
    runner = RecordingRunner();
    builder = LinuxToolboxBuilder(repo, runner, 'pinned-revision');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test(
    'symlink SDK cache copies its real directory without writing source markers',
    () async {
      final source = Directory('${temporary.path}/actual-sdk');
      final dart = File('${source.path}/bin/cache/dart-sdk/bin/dart');
      dart.parent.createSync(recursive: true);
      dart.writeAsBytesSync([0x7f, 69, 76, 70]);
      File('${source.path}/bin/flutter').writeAsStringSync('fixture');
      File(
        '${source.path}/bin/cache/flutter.version.json',
      ).writeAsStringSync(jsonEncode({'frameworkRevision': 'pinned-revision'}));
      final cache = Directory('${temporary.path}/fvm-cache/versions')
        ..createSync(recursive: true);
      Link('${cache.path}/pinned-revision').createSync(source.path);
      File(
        repo.path('config.yaml'),
      ).writeAsStringSync('flutter:\n  sdk_version: pinned-revision\n');
      final copy = SdkCopyRunner(cache.parent.path);
      final sdkBuilder = LinuxToolboxBuilder(repo, copy, 'pinned-revision');
      await sdkBuilder.prepare(BuildConfig.load(repo));
      expect(
        FileSystemEntity.typeSync(sdkBuilder.sdkRoot, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(File('${source.path}/.tempo-container-sdk').existsSync(), isFalse);
      expect(
        File('${sdkBuilder.sdkRoot}/.tempo-container-sdk').readAsStringSync(),
        'pinned-revision',
      );
      expect(copy.calls.single, contains('${source.path}:${source.path}:ro'));
    },
    skip: Platform.isWindows ? 'Linux SDK and Unix symlink path' : false,
  );
  test(
    'mounts only resolved external package roots read-only, not host home',
    () async {
      final external = Directory('${temporary.path}/cache/package with spaces')
        ..createSync(recursive: true);
      final internal = Directory(repo.path('packages/local'))
        ..createSync(recursive: true);
      final config = File(
        repo.path('toolbox/app/.dart_tool/package_config.json'),
      );
      config.parent.createSync(recursive: true);
      config.writeAsStringSync(
        jsonEncode({
          'packages': [
            {'name': 'external', 'rootUri': external.uri.toString()},
            {'name': 'internal', 'rootUri': internal.uri.toString()},
          ],
        }),
      );
      expect(builder.dependencyMounts(repo.path('toolbox/app')), [
        external.path,
      ]);
      await builder.run(builder.sdk.flutter, [
        'build',
        'linux',
        '--no-pub',
      ], workingDirectory: repo.path('toolbox/app'));
      final call = runner.calls.last;
      expect(call.first, 'podman');
      expect(call, contains('${external.path}:${external.path}:ro'));
      expect(call, isNot(contains('${temporary.path}:${temporary.path}:ro')));
      expect(call, contains('HOME=${repo.path('build/toolbox/linux-home')}'));
      expect(call, contains(builder.sdk.flutter));
    },
  );
  test(
    'missing dependency resolution refuses before starting a container',
    () async {
      expect(
        () => builder.dependencyMounts(repo.path('toolbox/app')),
        throwsA(isA<BuildFailure>()),
      );
      expect(runner.calls, isEmpty);
    },
  );
  test(
    'container builds keep host CMake output and configure a separate directory',
    () async {
      final config = File(
        repo.path('toolbox/app/.dart_tool/package_config.json'),
      );
      config.parent.createSync(recursive: true);
      config.writeAsStringSync('{"packages": []}');
      final output = File(
        repo.path('toolbox/app/build/linux/x64/debug/CMakeCache.txt'),
      );
      output.parent.createSync(recursive: true);
      output.writeAsStringSync('host compiler cache');
      for (final mode in ['--debug', '--release']) {
        await builder.run(builder.sdk.flutter, [
          'build',
          'linux',
          mode,
          '--no-pub',
        ], workingDirectory: repo.path('toolbox/app'));
      }
      expect(output.readAsStringSync(), 'host compiler cache');
      expect(builder.buildDirectory, repo.path('build/toolbox/flutter'));
      final configure = runner.calls.where((call) => call.contains('config'));
      expect(configure, hasLength(1));
      expect(
        configure.single,
        contains('--build-dir=../../build/toolbox/flutter'),
      );
      expect(
        configure.single,
        contains(
          'XDG_CONFIG_HOME=${repo.path('build/toolbox/linux-home/.config')}',
        ),
      );
      expect(runner.calls, hasLength(3));
    },
  );
}
