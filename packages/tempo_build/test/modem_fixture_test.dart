import 'dart:typed_data';
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

Uint8List words(List<int> values) {
  final result = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    result.setUint32(i * 4, values[i], Endian.little);
  }
  return result.buffer.asUint8List();
}

Uint8List packet(int operation, List<List<int>> arguments, {int padding = 0}) =>
    Uint8List.fromList([
      ...words([operation, arguments.length]),
      for (final arg in arguments) ...[
        ...words([arg.length]),
        ...arg,
        ...List.filled((-arg.length) % 4, padding),
      ],
    ]);
Uint8List record(int kind, int index, List<int> bytes) => Uint8List.fromList([
  ...words([kind, index, bytes.length]),
  ...bytes,
]);
void main() {
  test(
    'captured request identity ignores padding but preserves argument bytes',
    () {
      final a = packet(0x1001, [
        [97, 98, 99],
        [1, 0, 0, 0],
      ]);
      final b = packet(0x1001, [
        [97, 98, 99],
        [1, 0, 0, 0],
      ], padding: 255);
      expect(parseModemRequest(a).same(parseModemRequest(b)), isTrue);
      expect(
        parseModemRequest(a).same(
          parseModemRequest(
            packet(0x1001, [
              [97, 98, 100],
              [1, 0, 0, 0],
            ]),
          ),
        ),
        isFalse,
      );
      for (var length = 0; length < a.length; length++) {
        expect(
          () => parseModemRequest(Uint8List.sublistView(a, 0, length)),
          throwsFormatException,
          reason: 'truncation $length',
        );
      }
    },
  );
  test('oversized counts and payloads are rejected before reads', () {
    for (final bytes in [
      words([0x1001, 17]),
      words([0x1001, 1, 0xffffffff]),
      Uint8List(modemFsStride + 1),
    ]) {
      expect(() => parseModemRequest(bytes), throwsFormatException);
    }
  });
  test('trace requires bounded paired requests with matching operations', () {
    final request = packet(0x1001, [
      [102, 105, 108, 101, 0],
    ]);
    final response = packet(0xffff1001, [
      [0, 0, 0, 0],
    ]);
    final valid = Uint8List.fromList([
      ...record(1, 0, request),
      ...record(2, 0, response),
    ]);
    expect(parseModemTrace(valid), hasLength(1));
    for (final bytes in [
      <int>[],
      valid.sublist(0, valid.length - 1),
      record(1, 0, request),
      record(2, 0, response),
      [...record(1, 5, request), ...record(2, 5, response)],
      [...record(1, 0, request), ...record(2, 0, packet(0xffff1002, []))],
      [...record(1, 0, request), ...record(1, 0, request)],
    ]) {
      expect(
        () => parseModemTrace(Uint8List.fromList(bytes)),
        throwsFormatException,
      );
    }
  });
}
