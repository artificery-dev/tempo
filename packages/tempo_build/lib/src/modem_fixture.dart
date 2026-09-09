import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

const modemRom = 0xbe000000;
const modemRomSize = 0x1600000;
const modemSmem = 0xbf600000;
const modemSmemSize = 0x1c4000;
const modemGuestSmem = 0x41600000;
const modemFsOffset = 0xc0000;
const modemFsStride = 0x4004;
const modemFirmwareHash =
    '5059775975cbf6ab74c43978ca8f65d9a274b83585f456134e39b09f6dc7a4f1';

final class ModemRequest {
  ModemRequest(this.operation, this.arguments);
  final int operation;
  final List<Uint8List> arguments;
  bool same(ModemRequest other) {
    if (operation != other.operation ||
        arguments.length != other.arguments.length)
      return false;
    for (var i = 0; i < arguments.length; i++) {
      final a = arguments[i], b = other.arguments[i];
      if (a.length != b.length) return false;
      for (var j = 0; j < a.length; j++) {
        if (a[j] != b[j]) return false;
      }
    }
    return true;
  }

  bool get restoreQuery => operation == 0x101c && arguments.isEmpty;
}

ModemRequest parseModemRequest(Uint8List packet) {
  if (packet.length < 8 || packet.length > modemFsStride)
    throw const FormatException('Invalid FS packet size');
  final data = ByteData.sublistView(packet);
  final count = data.getUint32(4, Endian.little);
  if (count > 16) throw const FormatException('Invalid FS argument count');
  final args = <Uint8List>[];
  var pos = 8;
  for (var i = 0; i < count; i++) {
    if (pos + 4 > packet.length)
      throw const FormatException('Truncated FS argument header');
    final length = data.getUint32(pos, Endian.little);
    pos += 4;
    if (pos + length > packet.length)
      throw const FormatException('Truncated FS argument');
    args.add(Uint8List.fromList(packet.sublist(pos, pos + length)));
    pos += (length + 3) & ~3;
  }
  if (pos > packet.length) throw const FormatException('Truncated FS padding');
  return ModemRequest(data.getUint32(0, Endian.little), args);
}

typedef ModemExchange = (ModemRequest, Uint8List);
List<ModemExchange> parseModemTrace(Uint8List bytes) {
  final pending = <int, ModemRequest>{};
  final pairs = <ModemExchange>[];
  final data = ByteData.sublistView(bytes);
  var pos = 0;
  while (pos < bytes.length) {
    if (pos + 12 > bytes.length)
      throw const FormatException('Truncated trace header');
    final kind = data.getUint32(pos, Endian.little);
    final index = data.getUint32(pos + 4, Endian.little);
    final size = data.getUint32(pos + 8, Endian.little);
    pos += 12;
    if (index >= 5 || size > modemFsStride || pos + size > bytes.length)
      throw const FormatException('Invalid trace record');
    final packet = Uint8List.fromList(bytes.sublist(pos, pos + size));
    pos += size;
    final parsed = parseModemRequest(packet);
    if (kind == 1 && !pending.containsKey(index)) {
      pending[index] = parsed;
    } else if (kind == 2 && pending.containsKey(index)) {
      final request = pending.remove(index)!;
      if (parsed.operation != (request.operation | 0xffff0000))
        throw const FormatException('Mismatched FS response operation');
      pairs.add((request, packet));
    } else {
      throw const FormatException('Unpaired FS trace record');
    }
  }
  if (pending.isNotEmpty || pairs.isEmpty)
    throw const FormatException('Incomplete or empty FS trace');
  return pairs;
}

final class ModemFixture {
  ModemFixture(this.firmware, this.smem, this.exchanges, this.restoreReply);
  final Uint8List firmware, smem, restoreReply;
  final List<ModemExchange> exchanges;
  static Future<ModemFixture> load(String directory) async {
    final manifest =
        jsonDecode(await File('$directory/manifest.json').readAsString())
            as Map;
    final files = <String, Uint8List>{};
    for (final name in ['firmware.bin', 'smem.bin', 'fs.bin']) {
      final bytes = await File('$directory/$name').readAsBytes();
      final spec = (manifest['files'] as Map)[name] as Map;
      if (bytes.length != spec['size'] ||
          sha256.convert(bytes).toString() != spec['sha256'])
        throw FormatException('Fixture hash/size mismatch: $name');
      files[name] = bytes;
    }
    final firmware = files['firmware.bin']!, smem = files['smem.bin']!;
    if (sha256.convert(firmware).toString() != modemFirmwareHash ||
        firmware.length > modemRomSize)
      throw const FormatException('Not the audited Y2 2G modem firmware');
    if (smem.length != modemSmemSize)
      throw const FormatException('Incorrect shared memory size');
    final data = ByteData.sublistView(smem);
    final expected = <int, int>{
      0: 0x46494343,
      1: 0x3536544d,
      2: 0x31453238,
      3: 0x20121001,
      29: modemGuestSmem + modemFsOffset,
      30: modemFsStride * 5,
      31: modemGuestSmem + 0xbe000,
      32: 0x1008,
      69: 0x46494343,
    };
    for (final entry in expected.entries) {
      if (data.getUint32(entry.key * 4, Endian.little) != entry.value)
        throw const FormatException('Incorrect captured runtime layout');
    }
    final pairs = parseModemTrace(files['fs.bin']!);
    final restore = pairs.where((pair) => pair.$1.restoreQuery).toList();
    if (restore.length != 1)
      throw const FormatException(
        'Expected one captured FS restore-query response',
      );
    return ModemFixture(
      firmware,
      smem,
      pairs.where((pair) => !pair.$1.restoreQuery).toList(),
      restore.single.$2,
    );
  }
}
