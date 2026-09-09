import 'dart:convert';
import 'dart:typed_data';
import 'package:tempo_usb/src/browser/archive.dart';
import 'package:test/test.dart';

class MemoryArchive implements ArchiveFile {
  MemoryArchive(this.bytes);
  final Uint8List bytes;
  int get size => bytes.length;
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(bytes, offset, offset + length);
}

Uint8List archive({String name = 'manifest.json', bool duplicate = false}) {
  final encoded = utf8.encode(name), payload = utf8.encode('{}');
  final count = duplicate ? 2 : 1;
  final localSize = 30 + encoded.length + payload.length,
      centralSize = 46 + encoded.length;
  final bytes = Uint8List(count * (localSize + centralSize) + 22);
  final data = ByteData.sublistView(bytes);
  void u16(int offset, int value) =>
      data.setUint16(offset, value, Endian.little);
  void u32(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);
  for (var i = 0; i < count; i++) {
    final start = i * localSize, central = count * localSize + i * centralSize;
    u32(start, 0x04034b50);
    u16(start + 26, encoded.length);
    u32(start + 18, payload.length);
    u32(start + 22, payload.length);
    bytes.setRange(start + 30, start + 30 + encoded.length, encoded);
    bytes.setRange(start + 30 + encoded.length, start + localSize, payload);
    u32(central, 0x02014b50);
    u16(central + 28, encoded.length);
    u32(central + 20, payload.length);
    u32(central + 24, payload.length);
    u32(central + 42, start);
    bytes.setRange(central + 46, central + centralSize, encoded);
  }
  final end = bytes.length - 22;
  u32(end, 0x06054b50);
  u16(end + 8, count);
  u16(end + 10, count);
  u32(end + 12, count * centralSize);
  u32(end + 16, count * localSize);
  return bytes;
}

void main() {
  test('reads bounded local payload coordinates', () async {
    final bytes = archive();
    final entries = await parseArchive(MemoryArchive(bytes));
    expect(entries.single.name, 'manifest.json');
    expect(
      utf8.decode(
        bytes.sublist(
          entries.single.dataStart,
          entries.single.dataStart + entries.single.size,
        ),
      ),
      '{}',
    );
  });
  test('rejects traversal and duplicate names', () async {
    for (final bytes in [
      archive(name: '../boot.img'),
      archive(duplicate: true),
    ]) {
      await expectLater(
        parseArchive(MemoryArchive(bytes)),
        throwsFormatException,
      );
    }
  });
  test('rejects local versus central mismatch', () async {
    final bytes = archive();
    bytes[30] = 120;
    await expectLater(
      parseArchive(MemoryArchive(bytes)),
      throwsFormatException,
    );
  });
  test(
    'rejects payload into central directory and truncated archive',
    () async {
      final bytes = archive();
      ByteData.sublistView(bytes).setUint32(45 + 20, 1000, Endian.little);
      await expectLater(
        parseArchive(MemoryArchive(bytes)),
        throwsFormatException,
      );
      await expectLater(
        parseArchive(MemoryArchive(Uint8List(8))),
        throwsFormatException,
      );
    },
  );
}
