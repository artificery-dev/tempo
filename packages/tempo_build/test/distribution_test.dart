import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File rootfs;
  late String stock;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('tempo-dist-test-');
    rootfs = File(p.join(temporary.path, 'rootfs.ext4'))
      ..writeAsBytesSync(
        List.generate(12 * 1024 * 1024, (index) => index % 256),
      );
    File(p.join(temporary.path, 'logo.img')).writeAsStringSync('logo');
    File(p.join(temporary.path, 'boot.img')).writeAsStringSync('boot');
    File(p.join(temporary.path, 'recovery.img')).writeAsStringSync('recovery');
    final repo = Repository.locate();
    stock = repo.path(
      p.join(
        BuildConfig.load(repo).string('firmware.stock_rom'),
        'MT6582_Android_scatter.txt',
      ),
    );
  });
  tearDown(() => temporary.deleteSync(recursive: true));
  Future<Map<String, Object>> generate({
    int bootOffset = 0x2900000,
    String? scatter,
  }) => generateScatter(
    scatter: scatter ?? stock,
    destination: p.join(temporary.path, 'scatter.txt'),
    rootfs: rootfs.path,
    rootfsRaw: 0x5180000,
    rootfsSpan: 0x1cce80000,
    bootimgRaw: bootOffset,
    emmcSize: 0x1d2000000,
  );
  test(
    'retains geometry and independently reconstructs complete rootfs',
    () async {
      final manifest = await generate();
      final original = ScatterDocument.parse(File(stock).readAsStringSync());
      final actual = ScatterDocument.parse(
        File(p.join(temporary.path, 'scatter.txt')).readAsStringSync(),
      );
      expect(actual.blocks.length, original.blocks.length);
      for (var index = 0; index < actual.blocks.length; index++)
        for (final key in [
          'partition_name',
          'linear_start_addr',
          'physical_start_addr',
          'partition_size',
          'region',
          'is_reserved',
          'boundary_check',
        ])
          expect(
            ScatterDocument.field(actual.blocks[index], key),
            ScatterDocument.field(original.blocks[index], key),
          );
      final reconstructed = Uint8List(rootfs.lengthSync());
      final pieces = manifest['pieces'] as List<Map<String, Object>>;
      for (final piece in pieces) {
        final bytes = File(
          p.join(temporary.path, piece['file'] as String),
        ).readAsBytesSync();
        final offset = piece['rootfs_offset'] as int,
            length = piece['length'] as int,
            imageOffset = piece['image_offset'] as int;
        reconstructed.setRange(offset, offset + length, bytes, imageOffset);
      }
      expect(reconstructed, rootfs.readAsBytesSync());
      expect(pieces.map((piece) => piece['partition']), [
        'LOGO',
        'EBR2',
        'EXPDB',
        'ANDROID',
      ]);
      expect(
        File(
          p.join(temporary.path, 'rootfs-logo.bin'),
        ).readAsBytesSync().take(4),
        'logo'.codeUnits,
      );
      expect(
        actual.blocks
            .where(
              (block) => ScatterDocument.field(block, 'is_download') == 'true',
            )
            .map((block) => ScatterDocument.field(block, 'partition_name'))
            .toSet(),
        {'BOOTIMG', 'RECOVERY', 'LOGO', 'EBR2', 'EXPDB', 'ANDROID'},
      );
    },
  );
  test('rejects LOGO/rootfs overlap before writing pieces', () async {
    final logo = File(
      p.join(temporary.path, 'logo.img'),
    ).openSync(mode: FileMode.write);
    logo.truncateSync(0x200001);
    logo.closeSync();
    await expectLater(
      generate(),
      throwsA(
        isA<BuildFailure>().having(
          (e) => e.message,
          'message',
          contains('LOGO image overlaps'),
        ),
      ),
    );
    expect(File(p.join(temporary.path, 'rootfs-logo.bin')).existsSync(), false);
  });
  test('rejects unexpected raw address mapping', () async {
    await expectLater(
      generate(bootOffset: 0x1d80000),
      throwsA(isA<BuildFailure>()),
    );
  });
  test('rejects partition gaps without emitting pieces', () async {
    final broken = File(p.join(temporary.path, 'broken.txt'))
      ..writeAsStringSync(
        File(stock).readAsStringSync().replaceAll(
          'physical_start_addr: 0x4780000',
          'physical_start_addr: 0x47a0000',
        ),
      );
    await expectLater(
      generate(scatter: broken.path),
      throwsA(
        isA<BuildFailure>().having(
          (e) => e.message,
          'message',
          contains('gap'),
        ),
      ),
    );
    expect(File(p.join(temporary.path, 'rootfs-logo.bin')).existsSync(), false);
  });
}
