import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// Reading a palette off a picture: which ramps a set of pixels comes to.
void main() {
  /// A picture made of [bands], each an (r, g, b) filling an equal share of
  /// the width. Rows are identical, which is all the arithmetic looks at.
  Uint8List picture(List<(int, int, int)> bands, {int width = 64}) {
    const height = 8;
    final rgba = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final band =
            bands[(x * bands.length ~/ width).clamp(0, bands.length - 1)];
        final i = (y * width + x) * 4;
        rgba[i] = band.$1;
        rgba[i + 1] = band.$2;
        rgba[i + 2] = band.$3;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  List<WallpaperPalette> palettesOf(
    List<(int, int, int)> bands, {
    int count = 3,
  }) => WallpaperPalettes.fromPixels(
    picture(bands),
    width: 64,
    height: 8,
    count: count,
  );

  group('the color it reads as', () {
    test('a red picture comes to a red ramp', () {
      final palette = palettesOf([(220, 40, 40)]).first;
      expect(
        ['red', 'rose', 'orange'],
        contains(palette.primary),
        reason: 'got ${palette.primary}',
      );
    });

    test('a blue picture comes to a blue one', () {
      final palette = palettesOf([(40, 90, 220)]).first;
      expect(
        ['blue', 'indigo', 'sky', 'violet'],
        contains(palette.primary),
        reason: 'got ${palette.primary}',
      );
    });

    test('every name it picks is a ramp the system can dress', () {
      for (final palette in palettesOf([
        (200, 60, 60),
        (60, 160, 200),
        (240, 200, 40),
      ])) {
        expect(Swatch.named, contains(palette.primary));
        expect(Swatch.named, contains(palette.accent));
        expect(Swatch.named, contains(palette.neutral));
        expect(Swatch.grayNames, contains(palette.neutral));
      }
    });
  });

  group('the second color', () {
    test('is a different color, not a shade of the first', () {
      // Orange leads by area; teal is the other thing in the picture.
      final palette = palettesOf([
        (230, 130, 30),
        (230, 130, 30),
        (30, 170, 170),
      ]).first;
      expect(palette.accent, isNot(palette.primary));
    });

    test('a picture of one color still yields a pair', () {
      final palette = palettesOf([(220, 40, 40)]).first;
      expect(palette.accent, isNot(palette.primary));
      expect(Swatch.named, contains(palette.accent));
    });
  });

  group('the gray', () {
    test('a warm picture is framed in a warm gray', () {
      final warm = palettesOf([(200, 150, 90)]).first.neutral;
      final cool = palettesOf([(90, 150, 200)]).first.neutral;
      expect(Swatch.grayNames, contains(warm));
      expect(Swatch.grayNames, contains(cool));
      expect(warm, isNot(cool), reason: 'the cast should reach the gray');
    });

    test('a picture with no cast gets the gray that has none', () {
      expect(palettesOf([(128, 128, 128)]).first.neutral, 'gray');
    });
  });

  group('what it does with a picture that has nothing to say', () {
    test('a black and white one still dresses a UI', () {
      final palettes = palettesOf([(20, 20, 20), (235, 235, 235)]);
      expect(palettes, hasLength(1));
      expect(Swatch.named, contains(palettes.first.primary));
      expect(Swatch.named, contains(palettes.first.accent));
    });

    test('an empty or malformed picture is no palettes, not a crash', () {
      expect(
        WallpaperPalettes.fromPixels(Uint8List(0), width: 0, height: 0),
        isEmpty,
      );
      expect(
        WallpaperPalettes.fromPixels(Uint8List(4), width: 64, height: 64),
        isEmpty,
      );
    });
  });

  group('more than one palette', () {
    test('a picture with several colors offers several, all different', () {
      final palettes = palettesOf([
        (220, 50, 50),
        (50, 200, 90),
        (60, 90, 220),
      ], count: 3);
      expect(palettes.length, greaterThan(1));
      expect(
        palettes.map((p) => p.primary).toSet(),
        hasLength(palettes.length),
        reason: 'each palette should lead with a different color',
      );
      // They share the picture's one cast.
      expect(palettes.map((p) => p.neutral).toSet(), hasLength(1));
    });

    test('and never more than it was asked for', () {
      expect(
        palettesOf([
          (220, 50, 50),
          (50, 200, 90),
          (60, 90, 220),
          (230, 200, 40),
        ], count: 2),
        hasLength(2),
      );
    });
  });
}
