import 'dart:io';
import 'dart:typed_data';

import 'package:tempo_build/tempo_build.dart';
import 'package:toolbox_core/tone_analysis.dart';
import 'package:test/test.dart';

Uint8List toneWav({bool gap = false, bool silent = false}) {
  final bytes = Uint8List(444);
  final data = ByteData.sublistView(bytes);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(entry.key, entry.key + 4, entry.value.codeUnits);
  }
  for (final entry in {4: 436, 16: 16, 24: 1000, 28: 2000, 40: 400}.entries) {
    data.setUint32(entry.key, entry.value, Endian.little);
  }
  for (final entry in {20: 1, 22: 1, 32: 2, 34: 16}.entries) {
    data.setUint16(entry.key, entry.value, Endian.little);
  }
  for (var i = 0; i < 200; i++) {
    data.setInt16(
      44 + i * 2,
      silent || (gap && i >= 100 && i < 105) ? 0 : 2000,
      Endian.little,
    );
  }
  return bytes;
}

void main() {
  late Directory temp;
  late File wav;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('tone-routing-');
    wav = File('${temp.path}/tone.wav');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'shared analyzer preserves continuity, dropout and silence exit codes',
    () {
      for (final entry in [
        (toneWav(), 0, 'dropouts_at_least_5ms=0'),
        (toneWav(gap: true), 2, 'dropouts_at_least_5ms=1'),
        (toneWav(silent: true), 1, 'active_tone=none'),
      ]) {
        wav.writeAsBytesSync(entry.$1);
        final output = <String>[];
        expect(runToneAnalysis([wav.path], output: output.add), entry.$2);
        expect(output, contains(entry.$3));
      }
    },
  );

  test(
    'developer route runs with no repository or developer toolchain',
    () async {
      wav.writeAsBytesSync(toneWav(gap: true));
      expect(
        await runDeveloperCommand([
          'diagnostics',
          'analyze-tone',
          wav.path,
        ], repositoryRoot: '${temp.path}/not-a-repository'),
        2,
      );
    },
  );

  test('analyzer reports invalid input without mutating process exit code', () {
    final errors = <String>[];
    expect(runToneAnalysis([wav.path], errorOutput: errors.add), 64);
    expect(errors.single, startsWith('analyze-tone: '));
    expect(exitCode, 0);
  });

  test(
    'diagnostics help selects analyzer and rejects unknown actions',
    () async {
      expect(
        await runDeveloperCommand(['diagnostics', 'analyze-tone', '--help']),
        0,
      );
      expect(
        await runDeveloperCommand(['diagnostics', 'unknown', '--help']),
        2,
      );
    },
  );
}
