import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

class MountRunner extends CommandRunner {
  bool isMounted = false;
  bool failMount = false;
  int fsckCode = 0;
  final commands = <String>[];
  @override
  Future<ProcessResult> capture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool check = true,
  }) async {
    if (executable == 'mountpoint')
      return ProcessResult(0, isMounted ? 0 : 1, '', '');
    throw StateError(executable);
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
    commands.add(executable);
    if (executable == 'mount') {
      if (failMount) throw BuildFailure('mount failed');
      isMounted = true;
    }
    if (executable == 'umount') isMounted = false;
    return executable == 'e2fsck' ? fsckCode : 0;
  }
}

class OverlayRunner extends CommandRunner {
  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Stream<List<int>>? input,
    bool check = true,
  }) async {
    // The test exercises real copying and chmod without requiring root.
    if (executable == 'chown') return 0;
    return super.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      input: input,
      check: check,
    );
  }
}

void main() {
  test(
    'private checkout modes cannot restrict overlay directories or config',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'tempo-overlay-test-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final repo = Repository(temporary.path);
      final image = RootfsImage(repo, BuildConfig(repo, {}), OverlayRunner());
      final overlay = Directory(repo.path('platform/rootfs/overlay'));
      final config = File(p.join(overlay.path, 'etc/service/config'));
      config.parent.createSync(recursive: true);
      config.writeAsStringSync('public config\n');
      final executable = File(p.join(overlay.path, 'usr/bin/helper'));
      executable.parent.createSync(recursive: true);
      executable.writeAsStringSync('helper fixture\n');
      final private = File(image.at('etc/private'));
      private.parent.createSync(recursive: true);
      private.writeAsStringSync('private fixture\n');
      final outside = File(repo.path('outside'))
        ..writeAsStringSync('outside\n');
      Link(p.join(overlay.path, 'etc/link')).createSync(outside.path);
      await Process.run('chmod', ['-R', '700', overlay.path]);
      await Process.run('chmod', [
        '600',
        config.path,
        private.path,
        outside.path,
      ]);

      await image.stageOverlay();

      int mode(String name) => FileStat.statSync(name).mode & 0xfff;
      for (final name in ['', 'etc', 'etc/service', 'usr', 'usr/bin']) {
        expect(mode(image.at(name)), 0x1ed, reason: name); // 0755
      }
      expect(mode(image.at('etc/service/config')), 0x1a4); // 0644
      expect(mode(image.at('usr/bin/helper')), 0x1ed);
      expect(mode(private.path), 0x180); // 0600
      expect(mode(outside.path), 0x180);
      expect(Link(image.at('etc/link')).targetSync(), outside.path);
      expect(
        File(image.at('etc/service/config')).readAsStringSync(),
        'public config\n',
      );
    },
    skip: Platform.isWindows ? 'POSIX rootfs permissions' : false,
  );
  test(
    'mount refuses another owner and checks only safe fsck return codes',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'tempo-rootfs-test-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final repo = Repository(temporary.path);
      final runner = MountRunner();
      final image = RootfsImage(
        repo,
        BuildConfig(repo, {
          'device': {'hostname': 'test'},
        }),
        runner,
      );
      await image.open();
      expect(runner.isMounted, true);
      await expectLater(image.open(), throwsA(isA<BuildFailure>()));
      expect(runner.commands.where((c) => c == 'umount'), isEmpty);
      await image.close();
      expect(runner.isMounted, false);
      runner.fsckCode = 1;
      await image.check();
      runner.fsckCode = 2;
      await expectLater(image.check(), throwsA(isA<BuildFailure>()));
      expect(() => image.at('../../outside'), throwsA(isA<BuildFailure>()));
    },
  );
  test(
    'ELF reads actual host dynamic dependencies and rejects truncation',
    () async {
      final file = File('/usr/bin/true');
      if (!file.existsSync()) return;
      final elf = ElfDependencies(file.readAsBytesSync());
      expect(elf.interpreter, isNotNull);
      expect(elf.needed, contains('libc.so.6'));
      final readelf = await Process.run('readelf', ['-d', file.path]);
      for (final dependency in elf.needed)
        expect(readelf.stdout.toString(), contains('[$dependency]'));
      expect(() => ElfDependencies(Uint8List(3)), throwsFormatException);
      final broken = Uint8List.fromList(
        file.readAsBytesSync().take(20).toList(),
      );
      expect(
        () => ElfDependencies(broken).needed,
        throwsA(anyOf(isA<RangeError>(), isA<FormatException>())),
      );
    },
  );
  test('Plymouth closure stages SONAME contents, not dangling links', () async {
    if (!File('/usr/bin/true').existsSync()) return;
    final temporary = Directory.systemTemp.createTempSync(
      'tempo-plymouth-test-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final tree = Directory(p.join(temporary.path, 'tree'))..createSync();
    final output = p.join(temporary.path, 'output');
    void copy(String source, String relative) {
      final file = File(p.join(tree.path, relative));
      file.parent.createSync(recursive: true);
      File(source).copySync(file.path);
    }

    for (final executable in [
      'usr/sbin/plymouthd',
      'usr/bin/plymouth',
      'usr/lib/plymouth/details.so',
      'usr/lib/plymouth/script.so',
      'usr/lib/plymouth/renderers/drm.so',
    ])
      copy('/usr/bin/true', executable);
    final ldd = await Process.run('ldd', ['/usr/bin/true']);
    final libraries = RegExp(
      r'/[^\s()]+',
    ).allMatches(ldd.stdout.toString()).map((m) => m[0]!).toSet();
    for (final library in libraries) {
      copy(library, library.substring(1));
      if (p.dirname(library) != '/usr/lib')
        copy(library, 'usr/lib/${p.basename(library)}');
      if (p.dirname(library) != '/lib')
        copy(library, 'lib/${p.basename(library)}');
      if (p.basename(library) == 'libc.so.6') {
        final file = File(p.join(tree.path, library.substring(1)));
        file.renameSync('${file.path}.real');
        Link(file.path).createSync('${p.basename(file.path)}.real');
      }
    }
    // The rootfs loader search supports architecture directories under lib.
    for (final library in libraries.where(
      (path) => p.basename(path) == 'libc.so.6',
    )) {
      final target = File(p.join(tree.path, 'lib/libc.so.6'));
      if (!target.existsSync()) copy(library, 'lib/libc.so.6');
    }
    final conf = File(p.join(tree.path, 'etc/plymouth/plymouthd.conf'));
    conf.parent.createSync(recursive: true);
    conf.writeAsStringSync('[Daemon]\nTheme=tempo\n');
    final defaults = File(
      p.join(tree.path, 'usr/share/plymouth/plymouthd.defaults'),
    );
    defaults.parent.createSync(recursive: true);
    defaults.writeAsStringSync('');
    final theme = File(
      p.join(tree.path, 'usr/share/plymouth/themes/tempo/tempo.script'),
    );
    theme.parent.createSync(recursive: true);
    theme.writeAsStringSync('fixture');
    await stagePlymouth(tree.path, output, CommandRunner());
    expect(File(p.join(output, 'usr/bin/plymouth')).existsSync(), true);
    final libc = Directory(output)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => p.basename(file.path) == 'libc.so.6')
        .single;
    expect(FileSystemEntity.isLinkSync(libc.path), false);
    expect(ElfDependencies(libc.readAsBytesSync()).needed, isNotEmpty);
  });
}
