import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// Taking a picture in: what gets stored is the panel's own size, cropped
/// to cover it, and it carries the palettes read off the same pixels.
void main() {
  /// A picture [width] by [height], filled with one color, with a band of
  /// a second down the middle so there is something to read.
  List<int> pictureBytes(
    int width,
    int height, {
    (int, int, int) ground = (30, 90, 200),
    (int, int, int) band = (230, 140, 30),
  }) {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final middle = x > width ~/ 3 && x < width * 2 ~/ 3;
        final (r, g, b) = middle ? band : ground;
        image.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    return img.encodePng(image);
  }

  group('what is stored', () {
    test('covers the panel, whatever went in', () {
      for (final (w, h) in [(4000, 3000), (200, 200), (1000, 200), (60, 40)]) {
        final taken = Wallpapers.take(Uint8List.fromList(pictureBytes(w, h)));
        expect(taken, isNotNull, reason: '${w}x$h did not decode');
        final stored = img.decodeImage(taken!.bytes)!;
        // Never short of the panel on either side - a wallpaper with a
        // gap down the edge is not a wallpaper - and never more than the
        // overflow past it.
        expect(stored.width, greaterThanOrEqualTo(Wallpapers.width));
        expect(stored.height, greaterThanOrEqualTo(Wallpapers.height));
        expect(
          stored.width,
          lessThanOrEqualTo((Wallpapers.width * Wallpapers.overflow).round()),
          reason: '${w}x$h came out ${stored.width}x${stored.height}',
        );
        expect(
          stored.height,
          lessThanOrEqualTo((Wallpapers.height * Wallpapers.overflow).round()),
          reason: '${w}x$h came out ${stored.width}x${stored.height}',
        );
      }
    });

    test('keeps the picture\'s own shape, so Fit has something to fit', () {
      // 16:9 into a 4:3 panel: what comes back is still 16:9, so Contain
      // can letterbox it and Cover can crop it. Cut to the panel here,
      // the two would draw the same rectangle and the setting would be a
      // row that does nothing.
      final taken = Wallpapers.take(
        Uint8List.fromList(pictureBytes(1920, 1080)),
      )!;
      final stored = img.decodeImage(taken.bytes)!;
      expect(
        stored.width / stored.height,
        closeTo(1920 / 1080, 0.02),
        reason: 'came out ${stored.width}x${stored.height}',
      );
      expect(stored.height, Wallpapers.height);
    });

    test('and a panorama is cut back rather than carried whole', () {
      final taken = Wallpapers.take(
        Uint8List.fromList(pictureBytes(4000, 250)),
      )!;
      final stored = img.decodeImage(taken.bytes)!;
      expect(stored.height, Wallpapers.height);
      expect(
        stored.width,
        (Wallpapers.width * Wallpapers.overflow).round(),
        reason: 'came out ${stored.width}x${stored.height}',
      );
    });

    test('is smaller than a photograph, which is the point', () {
      final big = Uint8List.fromList(pictureBytes(3000, 2000));
      final taken = Wallpapers.take(big)!;
      expect(taken.bytes.length, lessThan(big.length));
    });

    test('is a picture in its own right, so the source can go away', () {
      final taken = Wallpapers.take(
        Uint8List.fromList(pictureBytes(800, 600)),
      )!;
      // Nothing about the original is referred to: these bytes decode on
      // their own.
      expect(img.decodeImage(taken.bytes), isNotNull);
    });
  });

  group('the crop', () {
    test('covers the panel rather than letterboxing it', () {
      // A very wide picture: the height is what has to reach, and the
      // width is trimmed. Neither dimension may come up short.
      final wide = img.Image(width: 2000, height: 200);
      final fitted = Wallpapers.stored(wide);
      expect(fitted.width, greaterThanOrEqualTo(Wallpapers.width));
      expect(fitted.height, Wallpapers.height);

      final tall = img.Image(width: 200, height: 2000);
      final fittedTall = Wallpapers.stored(tall);
      expect(fittedTall.width, Wallpapers.width);
      expect(fittedTall.height, greaterThanOrEqualTo(Wallpapers.height));
    });

    test('takes the middle of the picture', () {
      // Red left half, green right half, very wide: the crop keeps the
      // join, so both colors survive.
      final image = img.Image(width: 1200, height: 400);
      for (var y = 0; y < 400; y++) {
        for (var x = 0; x < 1200; x++) {
          image.setPixelRgba(
            x,
            y,
            x < 600 ? 220 : 20,
            x < 600 ? 20 : 200,
            20,
            255,
          );
        }
      }
      final fitted = Wallpapers.stored(image);
      final left = fitted.getPixel(2, fitted.height ~/ 2);
      final right = fitted.getPixel(fitted.width - 3, fitted.height ~/ 2);
      expect(left.r, greaterThan(left.g), reason: 'the left stayed red');
      expect(right.g, greaterThan(right.r), reason: 'the right stayed green');
    });
  });

  group('the palettes it carries', () {
    test('are read off the picture that was stored', () {
      final taken = Wallpapers.take(
        Uint8List.fromList(pictureBytes(800, 600)),
      )!;
      expect(taken.palettes, isNotEmpty);
      for (final palette in taken.palettes) {
        expect(Swatch.named, contains(palette.primary));
        expect(Swatch.named, contains(palette.accent));
        expect(Swatch.grayNames, contains(palette.neutral));
      }
    });

    test('and there are no more than asked for', () {
      final taken = Wallpapers.take(
        Uint8List.fromList(pictureBytes(400, 300)),
        palettes: 2,
      )!;
      expect(taken.palettes.length, lessThanOrEqualTo(2));
    });
  });

  group('the thumbnail a row gets', () {
    test('is a square of the size the picker draws', () {
      for (final (w, h) in [(1920, 1080), (600, 900), (40, 40), (30, 200)]) {
        final preview = Wallpapers.preview(
          Uint8List.fromList(pictureBytes(w, h)),
        );
        expect(preview.thumbnail, isNotNull, reason: '${w}x$h');
        final thumb = img.decodeImage(preview.thumbnail!)!;
        expect(
          (thumb.width, thumb.height),
          (Wallpapers.thumbSize, Wallpapers.thumbSize),
          reason: '${w}x$h came out ${thumb.width}x${thumb.height}',
        );
      }
    });

    test('is the middle of the picture, not the whole of it squashed', () {
      // Red left third, green middle, red right third, very wide: a
      // square of the middle is green through and through, where a
      // squashed one would still be mostly red.
      final image = img.Image(width: 900, height: 100);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 900; x++) {
          final middle = x >= 300 && x < 600;
          image.setPixelRgba(
            x,
            y,
            middle ? 20 : 220,
            middle ? 200 : 20,
            20,
            255,
          );
        }
      }
      final square = Wallpapers.square(image);
      final pixel = square.getPixel(square.width ~/ 2, square.height ~/ 2);
      expect(pixel.g, greaterThan(pixel.r));
      expect(square.width, square.height);
    });

    test('comes out of the same decode as the palettes', () {
      final preview = Wallpapers.preview(
        Uint8List.fromList(pictureBytes(400, 300)),
      );
      expect(preview.palettes, isNotEmpty);
      expect(preview.thumbnail, isNotNull);
    });

    test('and a picture that will not decode has neither', () {
      final preview = Wallpapers.preview(Uint8List.fromList([1, 2, 3, 4]));
      expect(preview.palettes, isEmpty);
      expect(preview.thumbnail, isNull);
    });
  });

  test('bytes that are not a picture are refused, not written', () {
    expect(Wallpapers.take(Uint8List.fromList([1, 2, 3, 4])), isNull);
    expect(Wallpapers.take(Uint8List(0)), isNull);
  });

  test('reading a picture works from another isolate', () async {
    // The picker decodes off the UI isolate. Everything the work touches
    // has to be sendable, and a closure that drags a Timer along with it
    // fails at the boundary rather than in the arithmetic - which is a
    // failure that looks, from the outside, like a picture with no colors.
    final bytes = Uint8List.fromList(pictureBytes(400, 300));
    final preview = await Isolate.run(() => Wallpapers.preview(bytes));
    expect(preview.palettes, isNotEmpty);
    expect(Swatch.named, contains(preview.palettes.first.primary));
    // And the thumbnail came back over the same wire.
    expect(preview.thumbnail, isNotNull);
  });
}
