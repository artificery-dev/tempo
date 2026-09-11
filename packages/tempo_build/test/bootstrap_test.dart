import 'dart:io';

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
    File(repo.path('config.yaml')).writeAsStringSync('user:\n  name: tempo\n');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test(
    'bad bootstrap options fail before host or private input setup',
    () async {
      for (final args in [
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
