import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  test('stock container round trips all charger blocks byte-for-byte', () {
    final path = Repository.locate().path('platform/firmware/stock/logo.bin');
    final stock = File(path).readAsBytesSync();
    final logo = LogoImage.parse(stock);
    expect(logo.name, 'LOGO');
    final encoded = logo.encode();
    expect(encoded, stock.take(encoded.length));
    final preserved = logo.blocks
        .skip(1)
        .map((block) => sha256.convert(block).toString())
        .toList();
    logo.blocks[0] = Uint8List.fromList(zlib.encode([1, 2, 3, 4]));
    final rebuilt = LogoImage.parse(logo.encode());
    expect(
      rebuilt.blocks.skip(1).map((block) => sha256.convert(block).toString()),
      preserved,
    );
  });
  test('RGB565 uses exact channel quantization and optional near black', () {
    final source = img.Image(width: 480, height: 360, numChannels: 3);
    source.setPixelRgb(1, 0, 255, 128, 8);
    final png = Uint8List.fromList(img.encodePng(source));
    final block = ByteData.sublistView(
      Uint8List.fromList(zlib.decode(pngLogoBlock(png))),
    );
    expect(block.getUint16(0, Endian.little), 0);
    expect(block.getUint16(2, Endian.little), 0xfc01);
    final near = ByteData.sublistView(
      Uint8List.fromList(zlib.decode(pngLogoBlock(png, nearBlack: true))),
    );
    expect(near.getUint16(0, Endian.little), 0x0841);
    expect(near.getUint16(2, Endian.little), 0xfc01);
  });
  test('rejects malformed geometry and output beyond partition boundary', () {
    expect(() => LogoImage.parse(Uint8List(512)), throwsFormatException);
    final valid = LogoImage('LOGO', [
      Uint8List.fromList([1, 2, 3]),
    ]).encode();
    ByteData.sublistView(valid).setUint32(520, 0, Endian.little);
    expect(() => LogoImage.parse(valid), throwsFormatException);
    expect(
      () => LogoImage('LOGO', [Uint8List(100)]).encode(maxSize: 520),
      throwsA(isA<BuildFailure>()),
    );
  });
}
