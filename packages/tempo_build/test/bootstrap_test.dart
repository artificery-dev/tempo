import 'dart:io';

import 'package:tempo_build/src/bootstrap.dart';
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Repository repo;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('bootstrap inputs ');
    repo = Repository(temporary.path);
    Directory(repo.path('app')).createSync();
    File(repo.path('pubspec.yaml')).writeAsStringSync('name: fixture\n');
    File(repo.path('config.yaml')).writeAsStringSync(
      'user:\n  name: tempo\nrootfs:\n  bluetooth_bootstrap_fixture: private-radio\n',
    );
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test(
    'reports all missing private inputs before running build tools',
    () async {
      await expectLater(
        validateFirmwareInputs(repo, BuildConfig.load(repo)),
        throwsA(
          isA<BuildFailure>()
              .having(
                (e) => e.message,
                'credentials',
                contains('user.ssh_keys'),
              )
              .having((e) => e.message, 'calibration', contains('--fixture')),
        ),
      );
    },
  );

  test('example credentials never pass bootstrap', () async {
    File(
      repo.path('config.local.yaml'),
    ).writeAsStringSync('user:\n  password: change-me\n');
    await expectLater(
      validateFirmwareInputs(repo, BuildConfig.load(repo)),
      throwsA(
        isA<BuildFailure>().having(
          (e) => e.message,
          'example',
          contains('Replace the example'),
        ),
      ),
    );
  });

  test(
    'configuration import preserves comments, modes and existing settings',
    () async {
      final source = File(repo.path('source.yaml'))
        ..writeAsStringSync(
          '# Private configuration\nuser:\n  password: testing\n',
        );
      final runner = CommandRunner();
      await importBootstrapInputs(repo, runner, configuration: source.path);
      final target = File(repo.path('config.local.yaml'));
      expect(target.readAsStringSync(), source.readAsStringSync());
      expect(target.statSync().mode & 0x1ff, 0x180);
      await importBootstrapInputs(repo, runner, configuration: source.path);
      source.writeAsStringSync('user:\n  password: replacement\n');
      await expectLater(
        importBootstrapInputs(repo, runner, configuration: source.path),
        throwsA(isA<BuildFailure>()),
      );
      expect(target.readAsStringSync(), contains('password: testing'));
    },
    skip: Platform.isWindows,
  );

  test(
    'bad bootstrap options fail before host or private input setup',
    () async {
      for (final args in [
        ['bootstrap', '--config'],
        ['bootstrap', '--fixture', '--build'],
        ['bootstrap', '--unexpected'],
        ['build', '--unexpected'],
      ]) {
        expect(await runDeveloperCommand(args, repositoryRoot: repo.root), 2);
      }
      expect(Directory(repo.path('build')).existsSync(), isFalse);
    },
  );
}
