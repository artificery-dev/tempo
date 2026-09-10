import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:tempo_build/src/cadence.dart';
import 'package:tempo_build/src/process.dart';
import 'package:test/test.dart';

void main() {
  late Directory bundle;
  late Map<String, String> hashes;
  void manifest() => File('${bundle.path}/manifest.json').writeAsStringSync(
    jsonEncode({'target': 'arm', 'sourceCommit': 'a' * 40, 'files': hashes}),
  );
  setUp(() {
    bundle = Directory.systemTemp.createTempSync('cadence-bundle-');
    hashes = {};
    for (final path in [
      'bin/cadenced',
      'lib/libcadence_probe.so',
      'lib/libsqlite3.so',
      'LICENSE',
    ]) {
      final bytes = path == 'LICENSE'
          ? utf8.encode('MIT')
          : <int>[127, 69, 76, 70, 1, 1, ...List.filled(12, 0), 40, 0];
      final file = File('${bundle.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      hashes[path] = sha256.convert(bytes).toString();
    }
    manifest();
  });
  tearDown(() => bundle.deleteSync(recursive: true));
  test('verifies complete ARM bundle and license', () async {
    expect(await verifyCadenceBundle(bundle.path), hashes);
  });
  test('rejects x64 runtime even when its checksum matches', () async {
    final file = File('${bundle.path}/bin/cadenced');
    final bytes = file.readAsBytesSync()
      ..[4] = 2
      ..[18] = 62;
    file.writeAsBytesSync(bytes);
    hashes['bin/cadenced'] = sha256.convert(bytes).toString();
    manifest();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
  });
  test('rejects missing native library and modified payload', () async {
    File('${bundle.path}/lib/libcadence_probe.so').deleteSync();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
    hashes.remove('lib/libcadence_probe.so');
    manifest();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
  });
  test('rejects paths outside the bundle', () async {
    hashes['../outside'] = 'a' * 64;
    manifest();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
  });
}
