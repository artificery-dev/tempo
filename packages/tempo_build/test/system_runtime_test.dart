import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:tempo_build/tempo_build.dart';
import 'package:tempo_build/src/system_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Map<String, Object?> manifest;
  void save() => File(
    '${directory.path}/manifest.json',
  ).writeAsStringSync(jsonEncode(manifest));
  Uint8List elf() {
    final bytes = Uint8List(64)..setAll(0, [127, 69, 76, 70, 1, 1]);
    bytes[18] = 40;
    return bytes;
  }

  void replace(String name, List<int> bytes, {bool updateHash = true}) {
    File('${directory.path}/$name').writeAsBytesSync(bytes);
    if (updateHash) {
      manifest[name] = sha256.convert(bytes).toString();
      save();
    }
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('system-runtime-verifier');
    manifest = {};
    replace('tempo-system', elf());
    replace('tempo-system.so', elf());
  });
  tearDown(() => directory.deleteSync(recursive: true));
  test(
    'accepts both verified ARM payloads and returns calculated hashes',
    () async {
      expect(await verifySystemRuntime(directory.path), manifest);
    },
  );
  test(
    'malformed JSON and non-map manifest cannot authorize runtime staging',
    () async {
      final file = File('${directory.path}/manifest.json');
      file.writeAsStringSync('{broken');
      await expectLater(
        verifySystemRuntime(directory.path),
        throwsFormatException,
      );
      for (final value in [null, [], 42, 'manifest']) {
        file.writeAsStringSync(jsonEncode(value));
        await expectLater(
          verifySystemRuntime(directory.path),
          throwsA(isA<BuildFailure>()),
        );
      }
    },
  );
  test('requires exactly the two owned manifest entries', () async {
    final expected = Map<String, Object?>.from(manifest);
    manifest.remove('tempo-system.so');
    save();
    await expectLater(
      verifySystemRuntime(directory.path),
      throwsA(isA<BuildFailure>()),
    );
    manifest = {...expected, 'unexpected.so': '0' * 64};
    save();
    await expectLater(
      verifySystemRuntime(directory.path),
      throwsA(isA<BuildFailure>()),
    );
    manifest = {
      'tempo-system': expected['tempo-system'],
      '../tempo-system.so': expected['tempo-system.so'],
    };
    save();
    await expectLater(
      verifySystemRuntime(directory.path),
      throwsA(isA<BuildFailure>()),
    );
  });
  for (final name in ['tempo-system', 'tempo-system.so']) {
    test('refuses missing $name despite a valid manifest', () async {
      File('${directory.path}/$name').deleteSync();
      await expectLater(
        verifySystemRuntime(directory.path),
        throwsA(isA<BuildFailure>()),
      );
    });
    test(
      'refuses $name directory or symlink in place of a regular file',
      () async {
        final path = '${directory.path}/$name';
        File(path).deleteSync();
        Directory(path).createSync();
        await expectLater(
          verifySystemRuntime(directory.path),
          throwsA(isA<BuildFailure>()),
        );
        Directory(path).deleteSync();
        final target = File('${directory.path}/outside')
          ..writeAsBytesSync(elf());
        Link(path).createSync(target.path);
        await expectLater(
          verifySystemRuntime(directory.path),
          throwsA(isA<BuildFailure>()),
        );
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires host privileges'
          : false,
    );
    test('refuses tampered $name and non-string digest', () async {
      replace(name, elf()..[40] = 99, updateHash: false);
      await expectLater(
        verifySystemRuntime(directory.path),
        throwsA(isA<BuildFailure>()),
      );
      replace(name, elf());
      manifest[name] = null;
      save();
      await expectLater(
        verifySystemRuntime(directory.path),
        throwsA(isA<BuildFailure>()),
      );
    });
    test('correct digest does not admit wrong architecture in $name', () async {
      for (final invalid in [
        Uint8List(19),
        elf()..[0] = 0,
        elf()..[4] = 2,
        elf()..[5] = 2,
        elf()..[18] = 62,
        elf()..[19] = 1,
      ]) {
        replace(name, invalid);
        await expectLater(
          verifySystemRuntime(directory.path),
          throwsA(isA<BuildFailure>()),
        );
      }
    });
  }
  test('missing manifest is a failed filesystem read', () async {
    File('${directory.path}/manifest.json').deleteSync();
    await expectLater(
      verifySystemRuntime(directory.path),
      throwsA(isA<FileSystemException>()),
    );
  });
}
