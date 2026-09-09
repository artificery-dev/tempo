import 'dart:io';
import 'package:tempo_data/tempo_data.dart';
import 'package:tempod/src/services/profile_access.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late TempoProfilePaths paths;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tempo-profile-access-');
    paths = TempoProfilePaths(
      data: '${root.path}/.tempo',
      config: '${root.path}/.config/tempo',
    );
    Directory(paths.data).createSync(recursive: true);
    Directory(paths.config).createSync(recursive: true);
    File('${paths.data}/library.db').writeAsStringSync('database');
    Directory('${root.path}/Music').createSync();
    File('${root.path}/Music/song.mp3').writeAsStringSync('media');
  });
  tearDown(() => root.delete(recursive: true));
  test(
    'changes only profile inventory and verifies access as frontend',
    () async {
      final calls = <(String, List<String>)>[];
      await ensureProfileAccess(
        paths,
        'tempo',
        command: (name, args) async {
          calls.add((name, args));
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(
        calls.any((c) => c.$1 == 'chown' && c.$2.contains('--no-dereference')),
        isTrue,
      );
      expect(calls.any((c) => c.$1 == 'chmod' && c.$2.first == '0600'), isTrue);
      expect(calls.any((c) => c.$1 == 'chmod' && c.$2.first == '0700'), isTrue);
      expect(
        calls.expand((c) => c.$2).any((s) => s.contains('/Music')),
        isFalse,
      );
      expect(calls.where((c) => c.$1 == 'runuser'), isNotEmpty);
    },
  );
  test('links refuse before ownership mutations', () async {
    Link('${paths.data}/outside').createSync('${root.path}/Music');
    var calls = 0;
    await expectLater(
      ensureProfileAccess(
        paths,
        'tempo',
        command: (name, args) async {
          calls++;
          return ProcessResult(1, 0, '', '');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(calls, 0);
  });
  test(
    'FAT ownership rejection is accepted only with working frontend access',
    () async {
      await ensureProfileAccess(
        paths,
        'tempo',
        command: (name, args) async => ProcessResult(
          1,
          name == 'runuser' ? 0 : 1,
          '',
          'unsupported ownership',
        ),
      );
      await expectLater(
        ensureProfileAccess(
          paths,
          'tempo',
          command: (name, args) async =>
              ProcessResult(1, 1, '', 'read-only filesystem'),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
