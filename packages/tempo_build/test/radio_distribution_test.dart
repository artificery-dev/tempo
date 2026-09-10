import 'dart:io';

import 'package:tempo_build/src/process.dart';
import 'package:tempo_build/src/radio_distribution.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('radio-assets-'));
  tearDown(() => directory.deleteSync(recursive: true));

  test('vendor firmware is allowed; either captured input blocks staging', () {
    final fixture = Directory('${directory.path}/fixture')..createSync();
    File('${fixture.path}/firmware.bin').writeAsBytesSync([1, 2, 3]);
    expect(() => rejectCapturedRadioBundle(directory), returnsNormally);
    for (final name in ['fs.bin', 'smem.bin']) {
      final capture = File('${fixture.path}/$name')..writeAsBytesSync([42]);
      expect(
        () => rejectCapturedRadioBundle(directory),
        throwsA(isA<BuildFailure>()),
      );
      capture.deleteSync();
    }
  });
}
