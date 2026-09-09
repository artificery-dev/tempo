import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tempo_build/src/bootstrap_sdk.dart';
import 'package:tempo_build/src/context.dart';
import 'package:tempo_build/src/process.dart';
import 'package:test/test.dart';

class SdkRunner extends CommandRunner {
  SdkRunner(this.version, {this.fail = false});
  final String version;
  bool fail;
  String dartVersion = '3.13.2';
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> capture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool check = true,
  }) async {
    calls.add([executable, ...arguments]);
    if (arguments.length == 1 && arguments.single == '--version') {
      return ProcessResult(1, 0, 'Dart SDK version: $dartVersion (stable)', '');
    }
    return ProcessResult(1, executable == 'podman' ? 0 : 1, '', '');
  }

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
    if (executable == 'podman' && arguments.contains('--version')) {
      if (fail) throw BuildFailure('Download interrupted', 23);
      final root = p.dirname(p.dirname(arguments[arguments.length - 2]));
      final metadata = File(p.join(root, 'bin/cache/flutter.version.json'));
      metadata.parent.createSync(recursive: true);
      metadata.writeAsStringSync(jsonEncode({'frameworkVersion': version}));
      final dart = File(FlutterSdk(root).dart);
      dart.parent.createSync(recursive: true);
      dart.writeAsStringSync('');
      File(FlutterSdk(root).flutter).writeAsStringSync('');
    }
    return 0;
  }
}

void main() {
  late Directory temporary;
  late Repository repository;
  late BuildConfig config;
  const version = 'bootstrap-test-pin';
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('sdk bootstrap ');
    repository = Repository(temporary.path);
    config = BuildConfig(repository, {
      'flutter': {'sdk_version': version},
    });
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test(
    'fresh SDK fetch uses official origin and can be repeated without FVM',
    () async {
      final runner = SdkRunner(version);
      final sdk = await provisionFlutterSdk(
        repository,
        config,
        runner,
        version,
      );
      expect(sdk.root, repository.path('build/sdks/flutter/$version'));
      expect(
        runner.calls.any(
          (call) => call.contains('https://github.com/flutter/flutter.git'),
        ),
        isTrue,
      );
      expect(
        runner.calls.any(
          (call) =>
              call.contains('fetch') &&
              call.contains('refs/tags/$version:refs/tags/$version'),
        ),
        isTrue,
      );
      runner.calls.clear();
      expect((await FlutterSdk.discover(config, runner)).root, sdk.root);
      expect(runner.calls, isEmpty);
      await provisionFlutterSdk(repository, config, runner, version);
      expect(runner.calls.any((call) => call.first == 'git'), isFalse);
    },
  );

  test('failed SDK bootstrap removes staging and can be retried', () async {
    final runner = SdkRunner(version, fail: true);
    await expectLater(
      provisionFlutterSdk(repository, config, runner, version),
      throwsA(isA<BuildFailure>().having((e) => e.code, 'code', 23)),
    );
    expect(
      Directory(repository.path('build/sdks/flutter')).listSync(),
      isEmpty,
    );
    runner.fail = false;
    await provisionFlutterSdk(repository, config, runner, version);
    expect(
      Directory(repository.path('build/sdks/flutter/$version')).existsSync(),
      isTrue,
    );
  });

  test('wrong version is rejected before publishing an SDK', () async {
    await expectLater(
      provisionFlutterSdk(repository, config, SdkRunner('wrong'), version),
      throwsA(isA<BuildFailure>()),
    );
    expect(
      Directory(repository.path('build/sdks/flutter')).listSync(),
      isEmpty,
    );
  });

  test(
    'bootstrap checks daemon Dart and caches only required Linux artifacts',
    () async {
      config.values['daemon'] = {
        'toolchain_version': version,
        'dart_version': '3.13.2',
      };
      final pin = File(repository.path('toolbox/app/.fvmrc'));
      pin.parent.createSync(recursive: true);
      pin.writeAsStringSync(jsonEncode({'flutter': version}));
      final runner = SdkRunner(version);
      await bootstrapSdks(repository, config, runner);
      final precache = runner.calls.singleWhere(
        (call) => call.contains('precache'),
      );
      expect(precache.last, '--linux');
      expect(precache, isNot(contains('--all-platforms')));
      expect(Link(repository.path('.fvm/flutter_sdk')).existsSync(), isTrue);
      runner.dartVersion = '0.0.0';
      runner.calls.clear();
      await expectLater(
        bootstrapSdks(repository, config, runner),
        throwsA(
          isA<BuildFailure>().having(
            (e) => e.message,
            'message',
            contains('required daemon Dart'),
          ),
        ),
      );
      expect(runner.calls.any((call) => call.contains('precache')), isFalse);
    },
  );

  test('invalid pin cannot escape checkout cache', () async {
    final runner = SdkRunner(version);
    await expectLater(
      provisionFlutterSdk(repository, config, runner, '../../elsewhere'),
      throwsA(isA<BuildFailure>()),
    );
    expect(runner.calls, isEmpty);
  });
}
