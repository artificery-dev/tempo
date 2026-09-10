import 'dart:typed_data';
import 'package:tempo_build/tempo_build.dart';

Uint8List _word(int value) => (ByteData(
  4,
)..setUint32(0, value & 0xffffffff, Endian.little)).buffer.asUint8List();

/// A bounded, ephemeral filesystem for the pinned modem's startup sequence.
/// The modem creates its own records. Nothing is read from another player or
/// written to eMMC; even writes to the modem's X:/Y: drives stay in RAM.
final class ModemFileSystem {
  final _files = <String, Uint8List>{};
  final _directories = <String>{'X:', 'Y:', 'Z:'};
  final _handles = <int, _Handle>{};
  static const _fileLimit = 1024 * 1024, _totalLimit = 4 * 1024 * 1024;
  int get fileCount => _files.length;
  int _integer(Uint8List value) {
    if (value.length != 4) throw const FormatException('Expected FS word');
    return ByteData.sublistView(value).getUint32(0, Endian.little);
  }

  String _path(Uint8List bytes) {
    if (bytes.length < 6 || bytes.length > 1024 || bytes.length.isOdd) {
      throw const FormatException('Invalid FS path length');
    }
    final data = ByteData.sublistView(bytes);
    final chars = [
      for (var i = 0; i < bytes.length; i += 2)
        data.getUint16(i, Endian.little),
    ];
    if (chars.removeLast() != 0 || chars.any((c) => c < 32 || c > 126)) {
      throw const FormatException('Invalid FS path encoding');
    }
    final path = String.fromCharCodes(
      chars,
    ).replaceAll(RegExp(r'\\+'), r'\').replaceFirst(RegExp(r'\\$'), '');
    final parts = path.split(r'\');
    if (!['X:', 'Y:', 'Z:'].contains(parts.first) ||
        parts
            .skip(1)
            .any(
              (p) =>
                  p.isEmpty ||
                  p == '.' ||
                  p == '..' ||
                  p.contains('/') ||
                  p.contains(':'),
            )) {
      throw const FormatException('Invalid FS path');
    }
    return path;
  }

  Uint8List respond(ModemRequest request) {
    final op = request.operation, args = request.arguments;
    const counts = {
      0x1001: 2,
      0x1002: 3,
      0x1003: 2,
      0x1004: 3,
      0x1005: 1,
      0x1007: 1,
      0x1009: 1,
      0x100e: 2,
      0x100f: 1,
      0x1010: 1,
      0x1011: 3,
      0x1012: 4,
      0x101c: 0,
    };
    if (counts[op] != args.length)
      throw FormatException('Unsupported FS request 0x${op.toRadixString(16)}');
    Uint8List result(int status, [List<Uint8List> extra = const []]) {
      final values = [_word(status), ...extra];
      final packet = Uint8List.fromList([
        ..._word(op | 0xffff0000),
        ..._word(values.length),
        for (final value in values) ...[
          ..._word(value.length),
          ...value,
          ...List<int>.filled((-value.length) % 4, 0),
        ],
      ]);
      if (packet.length > modemFsStride)
        throw const FormatException('FS reply exceeds buffer');
      return packet;
    }

    if (op == 0x101c) return result(0);
    if (op == 0x100e) {
      final info = ByteData(84);
      for (final entry in {12: 512, 13: 8, 14: 1024, 16: 512}.entries) {
        info.setUint32(entry.key * 4, entry.value, Endian.little);
      }
      return result(0, [info.buffer.asUint8List()]);
    }
    if ([0x1010, 0x1007, 0x100f, 0x1012, 0x1001, 0x1011].contains(op)) {
      final path = _path(args[0]);
      if (op == 0x1010)
        return result(
          _directories.contains(path)
              ? 16
              : _files.containsKey(path)
              ? 0
              : -9,
        );
      if (op == 0x1007) {
        if (_directories.length >= 128) throw StateError('FS directory quota');
        _directories.add(path);
        return result(0);
      }
      if (op == 0x100f) return result(_files.remove(path) != null ? 0 : -9);
      if (op == 0x1012) {
        if (args[1].length != 1 ||
            args[2].length != 1 ||
            _integer(args[3]) > 256)
          throw const FormatException('Invalid FS enumeration');
        final pattern = RegExp(
          '^${RegExp.escape(path).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}'
          r'$',
        );
        if (_files.keys.any(pattern.hasMatch))
          throw StateError('Unexpected nonempty startup enumeration');
        // FS_NO_MORE_FILES; empty returned filename, not the input capacity.
        return result(-6, [Uint8List(52), Uint8List(2)]);
      }
      final flags = _integer(args[1]);
      if (op == 0x1011 && args[2].length != 20)
        throw const FormatException('Invalid compact open');
      final extra = op == 0x1011
          ? [Uint8List.fromList(args[2].sublist(0, 8))]
          : <Uint8List>[];
      if (flags & 0x30000 != 0) {
        final split = path.lastIndexOf(r'\');
        if (split < 0 || !_directories.contains(path.substring(0, split)))
          return result(-9, extra);
        if (flags & 0x20000 != 0 || !_files.containsKey(path)) {
          if (!_files.containsKey(path) && _files.length >= 256)
            throw StateError('FS file quota');
          _files[path] = Uint8List(0);
        }
      }
      if (!_files.containsKey(path)) return result(-9, extra);
      final fd = [
        for (var i = 1; i <= 128; i++) i,
      ].where((i) => !_handles.containsKey(i)).firstOrNull;
      if (fd == null) return result(-5, extra);
      _handles[fd] = _Handle(path, flags & 0x30000 != 0);
      return result(fd, extra);
    }
    final fd = _integer(args[0]), handle = _handles[_integer(args[0])];
    if (handle == null)
      return result(-10, [
        if ([0x1003, 0x1004, 0x1009].contains(op)) _word(0),
        if (op == 0x1003) Uint8List(0),
      ]);
    var data = _files[handle.path]!;
    if (op == 0x1005) {
      _handles.remove(fd);
      return result(0);
    }
    if (op == 0x1009) return result(0, [_word(data.length)]);
    if (op == 0x1002) {
      _integer(args[1]);
      final offset = ByteData.sublistView(args[1]).getInt32(0, Endian.little),
          origin = _integer(args[2]);
      if (origin > 2) return result(-2);
      final position =
          offset +
          (origin == 0
              ? 0
              : origin == 1
              ? handle.position
              : data.length);
      if (position < 0 || position > _fileLimit) return result(-2);
      handle.position = position;
      return result(position);
    }
    if (op == 0x1003) {
      final count = _integer(args[1]);
      if (count > 16000) throw const FormatException('FS read exceeds buffer');
      final start = handle.position.clamp(0, data.length),
          end = (handle.position + count).clamp(0, data.length);
      final bytes = Uint8List.fromList(data.sublist(start, end));
      handle.position += bytes.length;
      return result(0, [_word(bytes.length), bytes]);
    }
    final count = _integer(args[2]), end = handle.position + _integer(args[2]);
    if (op != 0x1004 ||
        count != args[1].length ||
        !handle.writable ||
        end > _fileLimit)
      throw const FormatException('Invalid FS write');
    if (end > data.length) {
      final total =
          _files.values.fold(0, (sum, item) => sum + item.length) +
          end -
          data.length;
      if (total > _totalLimit) throw StateError('FS byte quota');
      final grown = Uint8List(end)..setAll(0, data);
      _files[handle.path] = data = grown;
    }
    data.setRange(handle.position, end, args[1]);
    handle.position = end;
    return result(0, [_word(count)]);
  }
}

final class _Handle {
  _Handle(this.path, this.writable);
  final String path;
  final bool writable;
  int position = 0;
}
