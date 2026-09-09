import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  test('MTK header and Android image geometry match stock format', () {
    final kernel = mtkHeader([1, 2, 3], 'KERNEL');
    final ramdisk = mtkHeader(List.filled(2048, 7), 'ROOTFS');
    expect(kernel.take(4), [0x88, 0x16, 0x88, 0x58]);
    expect(ByteData.sublistView(kernel).getUint32(4, Endian.little), 3);
    expect(ascii.decode(kernel.sublist(8, 14)), 'KERNEL');
    expect(kernel.sublist(40, 512), everyElement(255));
    final bytes = bootImage(kernel, ramdisk);
    final view = ByteData.sublistView(bytes);
    expect(ascii.decode(bytes.sublist(0, 8)), 'ANDROID!');
    expect(view.getUint32(8, Endian.little), 515);
    expect(view.getUint32(12, Endian.little), 0x10008000);
    expect(view.getUint32(16, Endian.little), 2560);
    expect(view.getUint32(20, Endian.little), 0x11000000);
    expect(view.getUint32(36, Endian.little), 2048);
    expect(bytes.length, 8192);
    // Byte-for-byte golden from the retired Python mk-bootimg implementation.
    expect(
      sha256.convert(bytes).toString(),
      'f7276ab4b356e16159d07b4c60059c46d393dd14a807a10f9693c8bdb6fdc0b4',
    );
    expect(bytes.sublist(2048, 2563), kernel);
    expect(bytes.sublist(4096, 6656), ramdisk);
    expect(
      () => bootImage(kernel, ramdisk, maxSize: 8191),
      throwsA(isA<BuildFailure>()),
    );
  });
  group('kernel source provenance', () {
    late Directory temporary;
    late Repository repo;
    late KernelSource kernel;
    late CommandRunner runner;
    late String source;
    Future<void> git(List<String> args) async {
      await runner.capture('git', args, workingDirectory: source);
    }

    setUp(() async {
      temporary = Directory.systemTemp.createTempSync('tempo-kernel-test-');
      repo = Repository(temporary.path);
      source = repo.path('platform/kernel/linux');
      Directory(
        p.join(source, 'arch/arm/boot/dts/mediatek'),
      ).createSync(recursive: true);
      File(
        p.join(source, 'arch/arm/boot/dts/mediatek/Makefile'),
      ).writeAsStringSync('\tmt6582-prestigio-pmt5008-3g.dtb \\\n');
      File(p.join(source, 'example')).writeAsStringSync('original\n');
      File(
        p.join(source, 'arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts'),
      ).writeAsStringSync('fixture device tree\n');
      runner = CommandRunner();
      kernel = KernelSource(repo, runner);
      await git(['init', '-q']);
      await git(['add', '.']);
      await git([
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.invalid',
        'commit',
        '-qm',
        'base',
      ]);
    });
    tearDown(() => temporary.deleteSync(recursive: true));
    test('records committed revision without changing the checkout', () async {
      await kernel.prepare();
      final before = kernel.state.readAsStringSync();
      await kernel.prepare();
      expect(kernel.state.readAsStringSync(), before);
      expect(File(p.join(source, 'example')).readAsStringSync(), 'original\n');
      File(
        p.join(source, 'example'),
      ).writeAsStringSync('new committed driver\n');
      await git(['add', '.']);
      await git([
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.invalid',
        'commit',
        '-qm',
        'driver update',
      ]);
      await kernel.prepare();
      expect(kernel.state.readAsStringSync(), isNot(before));
    });
    test('rejects tracked and staged edits without discarding them', () async {
      await kernel.prepare();
      final file = File(p.join(source, 'example'))
        ..writeAsStringSync('valuable experiment\n');
      await expectLater(kernel.prepare(), throwsA(isA<BuildFailure>()));
      expect(kernel.state.existsSync(), false);
      await git(['add', 'example']);
      await expectLater(kernel.prepare(), throwsA(isA<BuildFailure>()));
      await expectLater(kernel.reset(), throwsA(isA<BuildFailure>()));
      expect(file.readAsStringSync(), 'valuable experiment\n');
    });
    test(
      'rejects untracked source and symlinks without discarding them',
      () async {
        final file = File(p.join(source, 'new-driver.c'))
          ..writeAsStringSync('code');
        await expectLater(kernel.prepare(), throwsA(isA<BuildFailure>()));
        expect(file.readAsStringSync(), 'code');
        file.deleteSync();
        final link = Link(p.join(source, 'experiment'))
          ..createSync('/missing-target');
        await expectLater(kernel.prepare(), throwsA(isA<BuildFailure>()));
        expect(link.targetSync(), '/missing-target');
      },
    );
    test(
      'reset clears provenance only and leaves committed sources intact',
      () async {
        await kernel.prepare();
        await kernel.reset();
        expect(kernel.state.existsSync(), false);
        expect(
          File(p.join(source, 'example')).readAsStringSync(),
          'original\n',
        );
        expect(
          (await runner.capture('git', [
            'status',
            '--porcelain',
          ], workingDirectory: source)).stdout,
          '',
        );
      },
    );
    test('rejects a clean upstream tree without Y2 support', () async {
      await git(['rm', 'arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts']);
      await git([
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.invalid',
        'commit',
        '-qm',
        'upstream-only fixture',
      ]);
      await expectLater(kernel.prepare(), throwsA(isA<BuildFailure>()));
      expect(kernel.state.existsSync(), false);
    });
  });
}
