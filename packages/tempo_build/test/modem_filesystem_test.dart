import 'dart:typed_data';
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';
import '../../../platform/bluetooth/tool/modem_filesystem.dart';
import '../../../platform/bluetooth/tool/modem_runtime.dart';

Uint8List word(int n) => (ByteData(
  4,
)..setUint32(0, n & 0xffffffff, Endian.little)).buffer.asUint8List();
Uint8List path(String text) => Uint8List.fromList([
  for (final c in [...text.codeUnits, 0]) ...[c & 255, c >> 8],
]);
ModemRequest call(ModemFileSystem fs, int op, List<Uint8List> args) =>
    parseModemRequest(fs.respond(ModemRequest(op, args)));
int status(ModemRequest response) =>
    ByteData.sublistView(response.arguments.first).getInt32(0, Endian.little);
void main() {
  test('modem creates and reads its own records; instances share no data', () {
    final fs = ModemFileSystem();
    expect(status(call(fs, 0x1007, [path(r'Z:\\NVRAM')])), 0);
    final name = path(r'Z:\\NVRAM\\TEST');
    final fd = status(call(fs, 0x1001, [name, word(0x10000)]));
    expect(fd, greaterThan(0));
    final data = Uint8List.fromList([10, 20, 30]);
    expect(status(call(fs, 0x1004, [word(fd), data, word(data.length)])), 0);
    expect(status(call(fs, 0x1002, [word(fd), word(0), word(0)])), 0);
    expect(call(fs, 0x1003, [word(fd), word(100)]).arguments[2], data);
    expect(call(fs, 0x1003, [word(fd), word(100)]).arguments[2], isEmpty);
    expect(status(call(fs, 0x1005, [word(fd)])), 0);
    expect(status(call(fs, 0x1009, [word(fd)])), -10);
    expect(status(call(ModemFileSystem(), 0x1001, [name, word(0)])), -9);
  });
  test(
    'path traversal, invalid arguments, excessive reads and writes fail closed',
    () {
      final fs = ModemFileSystem();
      for (final name in [r'Z:\..\secret', r'Z:\a/secret', r'C:\secret']) {
        expect(
          () => call(fs, 0x1001, [path(name), word(0)]),
          throwsFormatException,
        );
      }
      expect(() => call(fs, 0x1003, []), throwsFormatException);
      final fd = status(call(fs, 0x1001, [path(r'Z:\TEST'), word(0x10000)]));
      expect(
        () => call(fs, 0x1003, [word(fd), word(0xffffffff)]),
        throwsFormatException,
      );
      expect(
        () => call(fs, 0x1004, [word(fd), Uint8List(1), word(100)]),
        throwsFormatException,
      );
      expect(status(call(fs, 0x1002, [word(fd), word(0x200000), word(0)])), -2);
    },
  );
  test(
    'empty enumeration returns actual empty name, not requested capacity',
    () {
      final fs = ModemFileSystem();
      final result = call(fs, 0x1012, [
        path(r'Z:\NVRAM\*'),
        Uint8List(1),
        Uint8List(1),
        word(64),
      ]);
      expect(status(result), -6);
      expect(result.arguments[1], hasLength(52));
      expect(result.arguments[2], hasLength(2));
    },
  );
  test('shared memory starts empty outside generated ABI structures', () {
    final bytes = modemSharedMemory();
    expect(bytes, hasLength(modemSmemSize));
    expect(bytes.skip(0xd24).every((byte) => byte == 0), isTrue);
    final words = ByteData.sublistView(bytes);
    final address = words.getUint32(29 * 4, Endian.little);
    final length = words.getUint32(30 * 4, Endian.little);
    expect(address, modemGuestSmem + modemFsOffset);
    expect(length, 5 * modemFsStride);
    expect(address + length, lessThanOrEqualTo(modemGuestSmem + bytes.length));
    bytes[0] = 0;
    expect(modemSharedMemory()[0], isNot(0));
  });
}
