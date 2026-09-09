import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tempo_build/src/distribution.dart';
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File scatter;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('tempo-installer-');
    File(p.join(temporary.path, 'boot.img')).writeAsStringSync('boot');
    File(p.join(temporary.path, 'logo.img')).writeAsStringSync('logo');
    scatter = File(p.join(temporary.path, 'scatter.txt'));
    final repo = Repository.locate();
    final document = ScatterDocument.parse(
      File(
        repo.path('platform/firmware/stock/MT6582_Android_scatter.txt'),
      ).readAsStringSync(),
    );
    for (final block in document.blocks) {
      final name = ScatterDocument.field(block, 'partition_name');
      ScatterDocument.setField(
        block,
        'is_download',
        ['PRELOADER', 'BOOTIMG', 'LOGO'].contains(name) ? 'true' : 'false',
      );
      if (name == 'BOOTIMG' || name == 'LOGO') {
        ScatterDocument.setField(
          block,
          'file_name',
          name == 'BOOTIMG' ? 'boot.img' : 'logo.img',
        );
      }
    }
    scatter.writeAsStringSync(document.encode());
  });
  tearDown(() => temporary.deleteSync(recursive: true));
  test(
    'installer uses raw USER addresses, sector padding and skips raw preloader',
    () async {
      final manifest = await installerManifest(
        scatter: scatter.path,
        version: 'test',
      );
      final images = (manifest['images'] as List).cast<Map<String, Object>>();
      expect(images.map((image) => image['file']), [
        'images/boot.img',
        'images/logo.img',
      ]);
      expect(images.first['size'], 512);
      expect(
        images.first['sha256'],
        sha256.convert([
          ...utf8.encode('boot'),
          ...List<int>.filled(508, 0),
        ]).toString(),
      );
      final write = (images.first['writes'] as List).single as Map;
      expect(write['target_offset'], 0x2900000);
      expect(write['region'], 'user');
      expect(write['length'], 512);
    },
  );
  test('rejects traversal and overlapping mappings', () async {
    final original = scatter.readAsStringSync();
    scatter.writeAsStringSync(original.replaceAll('boot.img', '../boot.img'));
    await expectLater(
      installerManifest(scatter: scatter.path, version: 'test'),
      throwsA(isA<BuildFailure>()),
    );
    scatter.writeAsStringSync(
      original.replaceAll(
        'physical_start_addr: 0x4400000',
        'physical_start_addr: 0x1d80000',
      ),
    );
    await expectLater(
      installerManifest(scatter: scatter.path, version: 'test'),
      throwsA(isA<BuildFailure>()),
    );
  });
  test('embeds identity icon without making it a flash image', () async {
    const icon = 'data:image/png;base64,aWNvbg==';
    final manifest = await installerManifest(
      scatter: scatter.path,
      version: '0.9.0',
      commit: '71e172f29e7a616ba578916307842d68df8df24d',
      icon: icon,
    );
    expect((manifest['firmware'] as Map)['icon'], icon);
    expect((manifest['firmware'] as Map)['version'], '0.9.0');
    expect(
      (manifest['firmware'] as Map)['commit'],
      '71e172f29e7a616ba578916307842d68df8df24d',
    );
    expect(
      (manifest['images'] as List).every(
        (image) => (image as Map)['file'] != 'icon',
      ),
      isTrue,
    );
  });
  test('rejects unknown address mapping and empty firmware identity', () async {
    await expectLater(
      installerManifest(scatter: scatter.path, version: 'test', userBias: 0),
      throwsA(isA<BuildFailure>()),
    );
    await expectLater(
      installerManifest(scatter: scatter.path, version: ''),
      throwsA(isA<BuildFailure>()),
    );
  });
}
