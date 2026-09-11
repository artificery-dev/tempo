import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:tempo_build/src/context.dart';
import 'package:tempo_build/src/process.dart';
import 'package:tempo_build/src/rootfs_container.dart';
import 'package:tempo_build/src/rootfs.dart';
import 'package:test/test.dart';

class RootfsRunner extends CommandRunner {
  final calls = <List<String>>[];
  bool failCompile = false;
  bool failSudo = false;
  bool staleRootfulImage = false;
  Map<String, dynamic>? receivedConfig;
  @override
  Future<ProcessResult> capture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool check = true,
  }) async {
    calls.add([executable, ...arguments]);
    return ProcessResult(
      0,
      0,
      executable == 'id'
          ? '1000\n'
          : (arguments.contains('inspect')
                ? (executable == 'sudo' && staleRootfulImage
                      ? 'old'
                      : 'current')
                : ''),
      '',
    );
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
    if (arguments.contains('compile') && failCompile)
      throw BuildFailure('compile failed', 9);
    if (executable == 'sudo' && failSudo)
      throw BuildFailure('sudo unavailable', 1);
    if (executable == 'sudo' && arguments.contains('TEMPO_ROOTFS_HOST=1')) {
      final index = arguments.indexOf('tempo-toolchain');
      receivedConfig =
          jsonDecode(File(arguments[index + 3]).readAsStringSync())
              as Map<String, dynamic>;
    }
    return 0;
  }
}

void main() {
  test(
    'rootfs lock refuses a competing process and releases after owner exits',
    () async {
      final directory = Directory.systemTemp.createTempSync('rootfs-lock-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final repo = Repository(directory.path);
      final lock = File(repo.path('build/rootfs-container/image.lock'));
      lock.parent.createSync(recursive: true);
      final script = File('${directory.path}/lock.dart')
        ..writeAsStringSync("""
import 'dart:io';
Future<void> main(List<String> args) async {
  final handle = File(args.single).openSync(mode: FileMode.append);
  await handle.lock(FileLock.exclusive);
  stdout.writeln('ready');
  await stdin.first;
  await handle.close();
}
""");
      final process = await Process.start(Platform.resolvedExecutable, [
        '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
        script.path,
        lock.path,
      ]);
      final error = process.stderr.transform(utf8.decoder).join();
      expect(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'ready',
      );
      try {
        await expectLater(
          withRootfsLock(repo, () async => fail('competing operation ran')),
          throwsA(isA<BuildFailure>().having((e) => e.code, 'busy exit', 73)),
        );
      } finally {
        process.stdin.writeln('release');
        await process.stdin.close();
        expect(await process.exitCode, 0, reason: await error);
      }
      expect(await withRootfsLock(repo, () async => 42), 42);
      expect(lock.existsSync(), isTrue);
    },
  );
  test(
    'rootful execution preserves argument boundaries and private mount propagation',
    () {
      final args = RootfsContainer.arguments(
        root: '/a checkout',
        helper: '/a checkout/helper',
        configuration: '/a checkout/config',
        uid: '1000',
        gid: '1001',
        command: ['shell', '--', 'printf', 'space ; literal'],
      );
      expect(
        args,
        containsAll([
          '--privileged',
          '--userns=host',
          '/a checkout:/a checkout:rw,rprivate',
          'SUDO_UID=1000',
          'SUDO_GID=1001',
        ]),
      );
      expect(args, isNot(contains('--pid=host')));
      expect(args, isNot(contains('--mount-propagation=shared')));
      expect(args.last, 'space ; literal');
    },
  );
  for (final stale in [false, true]) {
    test(
      'prerequisite probe isolates scratch and synchronizes image ($stale)',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'rootfs prerequisite ',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final repo = Repository(directory.path);
        final busybox = File(
          repo.path('platform/rootfs/initramfs/busybox/busybox-armv7l'),
        );
        busybox.parent.createSync(recursive: true);
        busybox.writeAsStringSync('fixture');
        final runner = RootfsRunner()..staleRootfulImage = stale;
        await RootfsContainer(
          repo,
          BuildConfig(repo, {}),
          runner,
        ).checkPrerequisites();
        expect(runner.calls.any((call) => call.contains('save')), stale);
        expect(runner.calls.any((call) => call.contains('load')), stale);
        final invocation = runner.calls.singleWhere(
          (call) => call.contains('run'),
        );
        expect(invocation, contains('--privileged'));
        expect(invocation, contains('--network=none'));
        expect(
          invocation,
          contains('${busybox.path}:/tempo-busybox:ro,rprivate'),
        );
        expect(invocation.join(' '), isNot(contains('build/os/rootfs')));
        expect(
          invocation.join(' '),
          isNot(contains('${repo.root}:${repo.root}')),
        );
        expect(
          invocation.last,
          contains(r'chroot "$work/mnt" /qemu-arm-static /busybox true'),
        );
        expect(
          Directory(repo.path('build/rootfs-container')).listSync(),
          isEmpty,
        );
      },
    );
  }
  test('sudo failure explains requirement before exporting image', () async {
    final directory = Directory.systemTemp.createTempSync(
      'rootfs prerequisite fail ',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final repo = Repository(directory.path);
    final busybox = File(
      repo.path('platform/rootfs/initramfs/busybox/busybox-armv7l'),
    );
    busybox.parent.createSync(recursive: true);
    busybox.writeAsStringSync('fixture');
    final runner = RootfsRunner()..failSudo = true;
    await expectLater(
      RootfsContainer(repo, BuildConfig(repo, {}), runner).checkPrerequisites(),
      throwsA(
        isA<BuildFailure>().having(
          (error) => error.message,
          'message',
          contains('Rootfs prerequisites failed'),
        ),
      ),
    );
    expect(runner.calls.any((call) => call.contains('save')), isFalse);
    expect(Directory(repo.path('build/rootfs-container')).listSync(), isEmpty);
  });
  for (final failure in [false, true]) {
    test(
      'the configuration reaches the helper by file, never argv, and temporary files are removed (failure=$failure)',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'rootfs container test ',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final repo = Repository(directory.path);
        final runner = RootfsRunner()..failCompile = failure;
        final config = BuildConfig(repo, {
          'user': {'name': 'never-in-command'},
        });
        final operation = RootfsContainer(
          repo,
          config,
          runner,
          dartExecutable: '/test/dart',
        ).run(['stage']);
        if (failure) {
          await expectLater(operation, throwsA(isA<BuildFailure>()));
          expect(runner.calls.where((call) => call.contains('run')), isEmpty);
        } else {
          expect(await operation, 0);
          expect(
            (runner.receivedConfig!['user'] as Map)['name'],
            'never-in-command',
          );
        }
        expect(
          runner.calls.expand((call) => call).join(' '),
          isNot(contains('never-in-command')),
        );
        expect(
          Directory(repo.path('build/rootfs-container')).listSync(),
          isEmpty,
        );
        expect(runner.calls.any((call) => call.contains('pub')), isFalse);
      },
    );
  }
}
