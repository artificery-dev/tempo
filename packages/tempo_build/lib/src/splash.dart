import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';

class LogoImage {
  LogoImage(this.name, this.blocks);
  final String name;
  final List<Uint8List> blocks;
  factory LogoImage.parse(Uint8List data) {
    if (data.length < 520) throw const FormatException('Truncated MTK logo');
    final view = ByteData.sublistView(data);
    if (view.getUint32(0, Endian.little) != 0x58881688)
      throw const FormatException('Bad MTK logo magic');
    final size = view.getUint32(4, Endian.little);
    if (size > data.length - 512 || size < 8)
      throw const FormatException('Truncated logo body');
    final count = view.getUint32(512, Endian.little);
    if (count == 0 ||
        count > (size - 8) ~/ 4 ||
        view.getUint32(516, Endian.little) != size)
      throw const FormatException('Invalid logo block table');
    final offsets = [
      for (var index = 0; index < count; index++)
        view.getUint32(520 + index * 4, Endian.little),
      size,
    ];
    if (offsets.first < 8 + count * 4)
      throw const FormatException('Logo block overlaps header table');
    final blocks = <Uint8List>[];
    for (var index = 0; index < count; index++) {
      if (offsets[index] >= offsets[index + 1] || offsets[index + 1] > size)
        throw const FormatException('Logo blocks overlap or exceed body');
      blocks.add(
        Uint8List.sublistView(
          data,
          512 + offsets[index],
          512 + offsets[index + 1],
        ),
      );
    }
    return LogoImage(
      ascii.decode(data.sublist(8, 40).takeWhile((byte) => byte != 0).toList()),
      blocks,
    );
  }
  Uint8List encode({int maxSize = 0x300000}) {
    if (blocks.isEmpty || ascii.encode(name).length > 32)
      throw const FormatException('Invalid logo name or block count');
    final table = 8 + 4 * blocks.length;
    final size =
        table + blocks.fold<int>(0, (sum, block) => sum + block.length);
    if (size + 512 > maxSize)
      throw BuildFailure('Logo exceeds $maxSize-byte partition');
    final bytes = Uint8List(512 + size)..fillRange(0, 512, 255);
    final view = ByteData.sublistView(bytes);
    view.setUint32(0, 0x58881688, Endian.little);
    view.setUint32(4, size, Endian.little);
    bytes.fillRange(8, 40, 0);
    bytes.setRange(8, 8 + name.length, ascii.encode(name));
    view.setUint32(512, blocks.length, Endian.little);
    view.setUint32(516, size, Endian.little);
    var offset = table;
    for (var index = 0; index < blocks.length; index++) {
      view.setUint32(520 + index * 4, offset, Endian.little);
      bytes.setRange(
        512 + offset,
        512 + offset + blocks[index].length,
        blocks[index],
      );
      offset += blocks[index].length;
    }
    return bytes;
  }
}

img.Image resizeLanczos(img.Image source, int width, int height) {
  if (width == source.width && height == source.height) return source.clone();
  List<List<(int, double)>> weights(int input, int output) {
    final ratio = input / output, support = math.max(1.0, input / output);
    double sinc(double x) => x == 0 ? 1 : math.sin(math.pi * x) / (math.pi * x);
    return List.generate(output, (target) {
      final centre = (target + .5) * ratio - .5;
      final entries = <(int, double)>[];
      for (
        var at = math.max(0, (centre - 3 * support).ceil());
        at <= math.min(input - 1, (centre + 3 * support).floor());
        at++
      ) {
        final distance = (at - centre) / support;
        entries.add((at, sinc(distance) * sinc(distance / 3)));
      }
      final total = entries.fold(0.0, (sum, e) => sum + e.$2);
      return entries.map((e) => (e.$1, e.$2 / total)).toList();
    });
  }

  final wx = weights(source.width, width), wy = weights(source.height, height);
  final intermediate = Float64List(width * source.height * 4);
  for (var y = 0; y < source.height; y++)
    for (var x = 0; x < width; x++) {
      final base = (y * width + x) * 4;
      for (final entry in wx[x]) {
        final pixel = source.getPixel(entry.$1, y),
            alpha = source.getPixel(entry.$1, y).a / 255;
        intermediate[base] += pixel.r * alpha * entry.$2;
        intermediate[base + 1] += pixel.g * alpha * entry.$2;
        intermediate[base + 2] += pixel.b * alpha * entry.$2;
        intermediate[base + 3] += pixel.a * entry.$2;
      }
    }
  final output = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++)
    for (var x = 0; x < width; x++) {
      final sums = List.filled(4, 0.0);
      for (final entry in wy[y])
        for (var channel = 0; channel < 4; channel++)
          sums[channel] +=
              intermediate[(entry.$1 * width + x) * 4 + channel] * entry.$2;
      final alpha = sums[3].clamp(0.0, 255.0),
          factor = alpha <= 0 ? 0.0 : 255 / alpha;
      output.setPixelRgba(
        x,
        y,
        (sums[0] * factor).round().clamp(0, 255),
        (sums[1] * factor).round().clamp(0, 255),
        (sums[2] * factor).round().clamp(0, 255),
        alpha.round(),
      );
    }
  return output;
}

Uint8List pngLogoBlock(Uint8List png, {bool nearBlack = false}) {
  var image = img.decodePng(png);
  if (image == null) throw const FormatException('Invalid PNG');
  image = resizeLanczos(image, 480, 360);
  final bytes = Uint8List(480 * 360 * 2), view = ByteData(480 * 360 * 2);
  for (var y = 0; y < 360; y++)
    for (var x = 0; x < 480; x++) {
      final pixel = image.getPixel(x, y);
      var value =
          ((pixel.r.toInt() >> 3) << 11) |
          ((pixel.g.toInt() >> 2) << 5) |
          (pixel.b.toInt() >> 3);
      if (value == 0 && nearBlack) value = 0x0841;
      view.setUint16((y * 480 + x) * 2, value, Endian.little);
    }
  bytes.setAll(0, view.buffer.asUint8List());
  return Uint8List.fromList(ZLibCodec(level: 9).encode(bytes));
}

Future<void> renderSplashAssets(Repository repo, CommandRunner runner) async {
  final owner = repo.path('platform/splash');
  final rendered = File(repo.path('build/os/splash/swirl-render-$pid.png'));
  rendered.parent.createSync(recursive: true);
  try {
    await Toolchain(repo, runner).run([
      'rsvg-convert',
      '-h',
      '800',
      p.join(owner, 'assets/openlogo-nd.svg'),
      '-o',
      rendered.path,
    ]);
    final source = img.decodePng(rendered.readAsBytesSync());
    if (source == null) throw BuildFailure('SVG renderer did not produce PNG');
    var left = source.width, top = source.height, right = 0, bottom = 0;
    for (final pixel in source)
      if (pixel.a > 0) {
        left = math.min(left, pixel.x);
        top = math.min(top, pixel.y);
        right = math.max(right, pixel.x);
        bottom = math.max(bottom, pixel.y);
      }
    if (left > right) throw BuildFailure('SVG is empty');
    final crop = img.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left + 1,
      height: bottom - top + 1,
    );
    final swirl = resizeLanczos(
      crop,
      (crop.width * 200 / crop.height).round(),
      200,
    );
    final boot = img.Image(width: 480, height: 360, numChannels: 3);
    img.compositeImage(boot, swirl, dstX: (480 - swirl.width) ~/ 2, dstY: 80);
    final dot = img.Image(width: 40, height: 40, numChannels: 4);
    for (var y = 0; y < 40; y++)
      for (var x = 0; x < 40; x++)
        dot.setPixelRgba(
          x,
          y,
          255,
          255,
          255,
          (x - 20) * (x - 20) + (y - 20) * (y - 20) <= 256 ? 255 : 0,
        );
    final bar = img.Image(width: 8, height: 8, numChannels: 4);
    img.fill(bar, color: img.ColorRgba8(255, 255, 255, 255));
    final assets = {
      p.join(owner, 'assets/boot-logo.png'): boot,
      p.join(owner, 'plymouth/tempo/logo.png'): swirl,
      p.join(owner, 'plymouth/tempo/dot.png'): resizeLanczos(dot, 10, 10),
      p.join(owner, 'plymouth/tempo/bar.png'): bar,
      repo.path('packages/tempo_core/assets/swirl.png'): boot,
    };
    for (final entry in assets.entries) {
      File(entry.key).parent.createSync(recursive: true);
      File(entry.key).writeAsBytesSync(img.encodePng(entry.value));
    }
  } finally {
    if (rendered.existsSync()) rendered.deleteSync();
  }
}

Future<int> splashCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  final action = args.isEmpty ? 'build' : args.removeAt(0);
  if (action == 'assets') {
    if (args.isNotEmpty) throw BuildFailure('Unexpected assets arguments', 2);
    await renderSplashAssets(repo, runner);
    return 0;
  }
  if (action == 'clean') {
    if (args.isNotEmpty) throw BuildFailure('Unexpected clean arguments', 2);
    final out = Directory(ArtifactPaths(repo).os('splash'));
    if (out.existsSync()) out.deleteSync(recursive: true);
    return 0;
  }
  if (action == 'info' || action == 'extract') {
    if (args.length != (action == 'info' ? 1 : 2))
      throw BuildFailure(
        'Expected splash $action IMAGE${action == 'extract' ? ' DIRECTORY' : ''}',
        2,
      );
    final logo = LogoImage.parse(File(args[0]).readAsBytesSync());
    stdout.writeln('${logo.name}: ${logo.blocks.length} blocks');
    for (var index = 0; index < logo.blocks.length; index++) {
      final block = logo.blocks[index];
      List<int>? raw;
      try {
        raw = zlib.decode(block);
      } on FormatException {
        /* Preserve unknown vendor blocks. */
      }
      if (action == 'info') {
        stdout.writeln(
          '$index: ${block.length} packed, ${raw?.length ?? 'unknown'} raw',
        );
        continue;
      }
      final prefix = p.join(
        args[1],
        'block-${index.toString().padLeft(2, '0')}',
      );
      Directory(args[1]).createSync(recursive: true);
      if (raw == null || raw.length % (480 * 2) != 0) {
        File('$prefix.bin').writeAsBytesSync(raw ?? block);
        continue;
      }
      final output = img.Image(
        width: 480,
        height: raw.length ~/ 960,
        numChannels: 3,
      );
      final bytes = ByteData.sublistView(Uint8List.fromList(raw));
      for (final pixel in output) {
        final value = bytes.getUint16(
          (pixel.y * 480 + pixel.x) * 2,
          Endian.little,
        );
        pixel.setRgb(
          ((value >> 11) & 31) << 3,
          ((value >> 5) & 63) << 2,
          (value & 31) << 3,
        );
      }
      File('$prefix.png').writeAsBytesSync(img.encodePng(output));
    }
    return 0;
  }
  if (action != 'build')
    throw BuildFailure(
      'Expected splash build, assets, info, extract, or clean',
      2,
    );
  var png = repo.path('platform/splash/assets/boot-logo.png'),
      template = repo.path('platform/firmware/stock/logo.bin'),
      output = repo.path('build/os/splash/logo.bin'),
      index = 0,
      bare = false,
      nearBlack = false;
  while (args.isNotEmpty) {
    final arg = args.removeAt(0);
    if (arg == '--bare') {
      bare = true;
      continue;
    }
    if (arg == '--near-black') {
      nearBlack = true;
      continue;
    }
    if (!arg.startsWith('-')) {
      png = arg;
      continue;
    }
    if (args.isEmpty) throw BuildFailure('$arg requires a value', 2);
    final value = args.removeAt(0);
    switch (arg) {
      case '-o':
      case '--output':
        output = value;
      case '-t':
      case '--template':
        template = value;
      case '-i':
      case '--index':
        index = int.parse(value);
      default:
        throw BuildFailure('Unknown splash build argument: $arg', 2);
    }
  }
  final block = pngLogoBlock(File(png).readAsBytesSync(), nearBlack: nearBlack);
  final logo = bare
      ? LogoImage('LOGO', [block])
      : LogoImage.parse(File(template).readAsBytesSync());
  if (index < 0 || index >= logo.blocks.length)
    throw BuildFailure('Logo block index is out of range');
  logo.blocks[index] = block;
  final bytes = logo.encode(
    maxSize: int.parse(config.string('device.partitions.logo_size')),
  );
  File(output).parent.createSync(recursive: true);
  File(output).writeAsBytesSync(bytes);
  stdout.writeln(
    'Logo: $output (${bytes.length} bytes, ${logo.blocks.length} blocks)',
  );
  return 0;
}
