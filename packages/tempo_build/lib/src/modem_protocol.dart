import 'dart:typed_data';

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
