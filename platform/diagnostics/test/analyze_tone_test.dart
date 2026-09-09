import 'dart:typed_data';
import 'package:toolbox_core/tone_analysis.dart';

Uint8List wav(List<int> samples, {int channels = 1}) {
  final bytes = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + 4, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, 1000, Endian.little);
  data.setUint32(28, channels * 2000, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes;
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void rejects(Uint8List bytes) {
  try {
    analyzeTone(bytes);
  } on FormatException {
    return;
  }
  throw StateError('malformed input accepted');
}

void main() {
  final result = analyzeTone(
    wav([
      ...List.filled(10, 0),
      ...List.filled(100, 2000),
      ...List.filled(5, 0),
      ...List.filled(100, -2000),
      ...List.filled(30, 0),
    ]),
  );
  check(
    result.first == 10 && result.last == 214,
    'trim leading/trailing silence',
  );
  check(
    result.gaps.length == 1 && result.gaps.single == (110, 115),
    'inclusive minimum gap',
  );
  check(result.rms.isNotEmpty, 'RMS windows');
  check(analyzeTone(wav(List.filled(100, 0))).first == null, 'all silence');
  final stereo = analyzeTone(
    wav([
      for (var i = 0; i < 100; i++) ...[0, -32768],
    ], channels: 2),
  );
  check(
    stereo.first == 0 && stereo.last == 99 && stereo.gaps.isEmpty,
    'loudest stereo channel and -32768',
  );
  rejects(Uint8List(2));
  final truncated = wav([1000, 1000]);
  rejects(truncated.sublist(0, truncated.length - 1));
  final wrongFormat = wav([1000]);
  wrongFormat[20] = 3;
  rejects(wrongFormat);
  final badAlignment = wav([1000]);
  badAlignment[32] = 4;
  rejects(badAlignment);
  print('analyze_tone: 8 checks passed');
}
