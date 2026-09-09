import 'dart:convert';
import 'dart:typed_data';

abstract interface class ArchiveFile {
  int get size;
  Future<Uint8List> read(int offset, int length);
}

class ArchiveEntry {
  ArchiveEntry({
    required this.name,
    required this.flags,
    required this.method,
    required this.size,
    required this.compressedSize,
    required this.localOffset,
    required this.index,
  });
  final String name;
  final int flags, method, size, compressedSize, localOffset, index;
  late int dataStart;
}

const _maxSafe = 9007199254740991;
void _range(int start, int length, int limit, String label) {
  if (start < 0 ||
      length < 0 ||
      start > _maxSafe ||
      length > _maxSafe ||
      start + length > limit ||
      start + length > _maxSafe)
    throw FormatException('$label is outside the firmware archive.');
}

int _u64(ByteData view, int offset) {
  final value = view.getUint64(offset, Endian.little);
  if (value > _maxSafe)
    throw const FormatException(
      'Firmware archive offset is too large for this browser.',
    );
  return value;
}

Map<String, int> _zip64(Uint8List extra, Map<String, bool> needed) {
  final view = ByteData.sublistView(extra);
  var cursor = 0;
  while (cursor + 4 <= extra.length) {
    final id = view.getUint16(cursor, Endian.little),
        length = view.getUint16(cursor + 2, Endian.little);
    cursor += 4;
    _range(cursor, length, extra.length, 'ZIP extra field');
    if (id == 1) {
      final values = <String, int>{};
      var position = cursor;
      for (final key in ['size', 'compressedSize', 'localOffset', 'disk']) {
        if (needed[key] != true) continue;
        final width = key == 'disk' ? 4 : 8;
        if (position + width > cursor + length)
          throw const FormatException('Truncated ZIP64 field.');
        values[key] = width == 8
            ? _u64(view, position)
            : view.getUint32(position, Endian.little);
        position += width;
      }
      return values;
    }
    cursor += length;
  }
  throw const FormatException('Missing required ZIP64 values.');
}

Future<List<ArchiveEntry>> parseArchive(ArchiveFile file) async {
  final tailStart = (file.size - (0xffff + 22 + 20)).clamp(0, file.size);
  final tail = await file.read(tailStart, file.size - tailStart);
  final view = ByteData.sublistView(tail);
  var eocd = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50 &&
        i + 22 + view.getUint16(i + 20, Endian.little) == tail.length) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0)
    throw const FormatException('File is not a complete ZIP firmware archive.');
  if (view.getUint16(eocd + 4, Endian.little) != 0 ||
      view.getUint16(eocd + 6, Endian.little) != 0)
    throw const FormatException(
      'Multi-disk firmware archives are not supported.',
    );
  var count = view.getUint16(eocd + 10, Endian.little),
      size = view.getUint32(eocd + 12, Endian.little),
      offset = view.getUint32(eocd + 16, Endian.little);
  if (count == 0xffff || size == 0xffffffff || offset == 0xffffffff) {
    final locator = eocd - 20;
    if (locator < 0 || view.getUint32(locator, Endian.little) != 0x07064b50)
      throw const FormatException('Missing ZIP64 locator.');
    final recordOffset = _u64(view, locator + 8);
    _range(recordOffset, 56, file.size, 'ZIP64 directory');
    final record = ByteData.sublistView(await file.read(recordOffset, 56));
    if (record.lengthInBytes < 56 ||
        record.getUint32(0, Endian.little) != 0x06064b50)
      throw const FormatException('Invalid ZIP64 directory.');
    if (record.getUint32(16, Endian.little) != 0 ||
        record.getUint32(20, Endian.little) != 0)
      throw const FormatException('Multi-disk ZIP64 archive.');
    count = _u64(record, 32);
    size = _u64(record, 40);
    offset = _u64(record, 48);
  }
  _range(offset, size, tailStart + eocd, 'ZIP central directory');
  if (count < 1 || count > 257 || size > 16 * 1024 * 1024)
    throw const FormatException('Firmware directory is unreasonably large.');
  final bytes = await file.read(offset, size);
  // Keep only the bounded directory in memory; payload bytes are streamed later.
  final directory = ByteData.sublistView(bytes);
  final entries = <ArchiveEntry>[];
  var cursor = 0;
  for (var index = 0; index < count; index++) {
    if (cursor + 46 > bytes.length ||
        directory.getUint32(cursor, Endian.little) != 0x02014b50)
      throw const FormatException('Malformed central directory.');
    final madeBy = bytes[cursor + 5],
        flags = directory.getUint16(cursor + 8, Endian.little),
        method = directory.getUint16(cursor + 10, Endian.little);
    var compressed = directory.getUint32(cursor + 20, Endian.little),
        entrySize = directory.getUint32(cursor + 24, Endian.little),
        local = directory.getUint32(cursor + 42, Endian.little);
    final nameLength = directory.getUint16(cursor + 28, Endian.little),
        extraLength = directory.getUint16(cursor + 30, Endian.little),
        commentLength = directory.getUint16(cursor + 32, Endian.little);
    _range(
      cursor + 46,
      nameLength + extraLength + commentLength,
      bytes.length,
      'ZIP entry',
    );
    if (flags & 1 != 0)
      throw const FormatException(
        'Encrypted firmware entries are not supported.',
      );
    if (method != 0 && method != 8)
      throw FormatException('Unsupported ZIP compression method $method.');
    final name = utf8.decode(
      bytes.sublist(cursor + 46, cursor + 46 + nameLength),
      allowMalformed: false,
    );
    if (name.isEmpty ||
        name.endsWith('/') ||
        name.startsWith('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        name.contains('\u0000') ||
        name
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..'))
      throw FormatException('Unsafe firmware entry $name.');
    final mode = madeBy == 3
        ? directory.getUint32(cursor + 38, Endian.little) >> 16
        : 0;
    if (mode & 0xf000 == 0xa000)
      throw FormatException('Symbolic link $name is not allowed.');
    final disk = directory.getUint16(cursor + 34, Endian.little);
    final needed = {
      'size': entrySize == 0xffffffff,
      'compressedSize': compressed == 0xffffffff,
      'localOffset': local == 0xffffffff,
      'disk': disk == 0xffff,
    };
    if (needed.values.any((v) => v)) {
      final values = _zip64(
        bytes.sublist(
          cursor + 46 + nameLength,
          cursor + 46 + nameLength + extraLength,
        ),
        needed,
      );
      entrySize = values['size'] ?? entrySize;
      compressed = values['compressedSize'] ?? compressed;
      local = values['localOffset'] ?? local;
      if ((values['disk'] ?? disk) != 0)
        throw const FormatException('Multi-disk firmware archive.');
    } else if (disk != 0) {
      throw const FormatException('Multi-disk firmware archive.');
    }
    entries.add(
      ArchiveEntry(
        name: name,
        flags: flags,
        method: method,
        size: entrySize,
        compressedSize: compressed,
        localOffset: local,
        index: index,
      ),
    );
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  if (cursor != bytes.length)
    throw const FormatException('Central directory has trailing data.');
  final names = <String>{};
  for (final entry in entries) {
    if (!names.add(entry.name))
      throw FormatException('Duplicate firmware entry ${entry.name}.');
    _range(entry.localOffset, 30, offset, 'Local ZIP header');
    final header = ByteData.sublistView(await file.read(entry.localOffset, 30));
    if (header.lengthInBytes != 30 ||
        header.getUint32(0, Endian.little) != 0x04034b50)
      throw FormatException('Missing local ZIP header for ${entry.name}.');
    final nameLength = header.getUint16(26, Endian.little),
        extraLength = header.getUint16(28, Endian.little);
    _range(
      entry.localOffset + 30,
      nameLength + extraLength,
      offset,
      'Local ZIP fields',
    );
    final localName = utf8.decode(
      await file.read(entry.localOffset + 30, nameLength),
      allowMalformed: false,
    );
    if (localName != entry.name ||
        header.getUint16(6, Endian.little) != entry.flags ||
        header.getUint16(8, Endian.little) != entry.method)
      throw FormatException(
        'Central and local headers disagree for ${entry.name}.',
      );
    entry.dataStart = entry.localOffset + 30 + nameLength + extraLength;
    _range(entry.dataStart, entry.compressedSize, offset, 'Compressed data');
  }
  final sorted = [...entries]
    ..sort((a, b) => a.localOffset.compareTo(b.localOffset));
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].localOffset <
        sorted[i - 1].dataStart + sorted[i - 1].compressedSize)
      throw const FormatException('Firmware entries overlap.');
  }
  if (sorted.first.localOffset != 0)
    throw const FormatException('Firmware archive has a prefix.');
  return entries;
}
