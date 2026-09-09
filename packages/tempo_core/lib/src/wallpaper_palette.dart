import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tomeui/tomeui.dart';

/// Three swatches drawn out of a picture: what the UI is mixed from when
/// a color slot is set to follow the wallpaper.
///
/// Named swatches rather than raw colors on purpose. The whole UI is built
/// out of [Swatch] ramps - a surface asks for the 400 or the 950 of what it
/// is wearing - so a color taken off a picture is only useful once it has
/// been matched to one of the ramps the system already knows how to dress.
@immutable
class WallpaperPalette {
  const WallpaperPalette({
    required this.primary,
    required this.accent,
    required this.neutral,
  });

  /// Names from [Swatch.named].
  final String primary;
  final String accent;
  final String neutral;

  /// The name for [role], or null for a role a palette does not name.
  String? operator [](String role) => switch (role) {
    'primary' => primary,
    'accent' => accent,
    'neutral' => neutral,
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is WallpaperPalette &&
      other.primary == primary &&
      other.accent == accent &&
      other.neutral == neutral;

  @override
  int get hashCode => Object.hash(primary, accent, neutral);

  @override
  String toString() => 'WallpaperPalette($primary, $accent, $neutral)';
}

/// Reading palettes off a picture.
///
/// The method is a weighted hue histogram, which is the cheap answer that
/// happens also to be the right one here. The alternative - clustering in a
/// perceptual space - finds the colors that cover the most *area*, and the
/// most area in a photograph is usually its sky or its wall. What a UI
/// wants is the color the picture reads *as*, which is the one that is both
/// saturated and present: a small bright thing beats a large dull one.
///
/// So every pixel votes for its hue, weighted by how colorful it is and how
/// far it is from black and white, and the ramps are matched to the hues
/// that win. The grays are chosen separately, off the picture's own cast.
abstract final class WallpaperPalettes {
  /// How wide the picture is sampled at. Small on purpose: the hues of a
  /// picture survive being shrunk, and a panel-sized image is a hundred
  /// thousand pixels to walk otherwise.
  static const sampleWidth = 64;

  /// How far apart two hues must be, in degrees, before they count as two
  /// colors rather than two shades of one - the primary and the accent
  /// have to be told apart at a glance.
  static const minimumHueGap = 40.0;

  /// Below this saturation a pixel is telling us about the picture's gray,
  /// not about its color.
  static const _colorfulEnough = 0.18;

  /// The swatches a color slot may be matched to, and the grays a neutral
  /// may be.
  static List<String> get colorNames => Swatch.colorNames;

  static List<String> get grayNames => Swatch.grayNames;

  /// The palettes a picture suggests, best first, at most [count] of them,
  /// from its raw RGBA bytes.
  ///
  /// Every palette shares the neutral - the picture has one cast - and
  /// differs in which pair of its colors leads.
  ///
  /// Takes bytes rather than an image so the arithmetic can be tested
  /// against pictures made up on the spot, and so it does not care which
  /// decoder produced them. [Wallpapers.take] is what feeds it a file.
  static List<WallpaperPalette> fromPixels(
    Uint8List rgba, {
    required int width,
    required int height,
    int count = 3,
  }) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return const [];
    }

    // One bucket per swatch: every colorful pixel votes for the ramp it is
    // nearest, so the winners are already the names we can dress in.
    final votes = <String, double>{for (final name in colorNames) name: 0};
    var castR = 0.0, castG = 0.0, castB = 0.0, castWeight = 0.0;

    // Every nth pixel, so a big picture costs what a small one does.
    final step = math.max(1, (width / sampleWidth).round());
    for (var y = 0; y < height; y += step) {
      for (var x = 0; x < width; x += step) {
        final i = (y * width + x) * 4;
        final a = rgba[i + 3];
        if (a < 128) continue;
        final r = rgba[i] / 255, g = rgba[i + 1] / 255, b = rgba[i + 2] / 255;
        final (hue, saturation, lightness) = _hsl(r, g, b);

        // The picture's cast is everything, colorful or not: a gray is
        // chosen against the whole image rather than against its accents.
        castR += r;
        castG += g;
        castB += b;
        castWeight += 1;

        if (saturation < _colorfulEnough) continue;
        // Weighted toward the middle of the ramp: a color the UI can wear
        // is one that is neither nearly black nor nearly white.
        final room = 1 - (2 * lightness - 1).abs();
        final weight = saturation * room * room;
        if (weight <= 0) continue;
        votes[_nearestColor(hue)] = votes[_nearestColor(hue)]! + weight;
      }
    }

    final ranked = votes.entries.where((entry) => entry.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final neutral = castWeight == 0
        ? 'zinc'
        : _nearestGray(
            castR / castWeight,
            castG / castWeight,
            castB / castWeight,
          );

    // A picture with no color in it at all - a black and white photograph -
    // still has to dress a UI, and the grays are what it has.
    if (ranked.isEmpty) {
      return [
        WallpaperPalette(primary: 'sky', accent: 'blue', neutral: neutral),
      ];
    }

    final palettes = <WallpaperPalette>[];
    for (final lead in ranked) {
      if (palettes.length >= count) break;
      final accent = _partnerFor(lead.key, ranked);
      final palette = WallpaperPalette(
        primary: lead.key,
        accent: accent,
        neutral: neutral,
      );
      if (!palettes.contains(palette)) palettes.add(palette);
    }
    return palettes;
  }

  /// The color that goes beside [primary]: the next best-supported one far
  /// enough round the wheel to read as a second color, or - where the
  /// picture only really has one - a neighbour of the primary's own, so the
  /// pair still agree.
  static String _partnerFor(
    String primary,
    List<MapEntry<String, double>> ranked,
  ) {
    final lead = _hueOf(primary);
    for (final entry in ranked) {
      if (entry.key == primary) continue;
      if (_hueGap(lead, _hueOf(entry.key)) >= minimumHueGap) return entry.key;
    }
    // Nothing far enough away: step along the ramp of names, which runs
    // round the wheel, so the accent is the primary's neighbour.
    final at = colorNames.indexOf(primary);
    return colorNames[(at + 2) % colorNames.length];
  }

  /// The swatch whose own hue is nearest [hue].
  static String _nearestColor(double hue) {
    var best = colorNames.first;
    var bestGap = 360.0;
    for (final name in colorNames) {
      final gap = _hueGap(hue, _hueOf(name));
      if (gap < bestGap) {
        bestGap = gap;
        best = name;
      }
    }
    return best;
  }

  /// The gray whose own cast is nearest the picture's average.
  ///
  /// The grays are not neutral: slate is blue, stone is warm, olive is
  /// green. Matching them to the picture is what stops a warm photograph
  /// being framed in a cold gray.
  static String _nearestGray(double r, double g, double b) {
    final (hue, saturation, _) = _hsl(r, g, b);
    // A picture with no cast at all gets the gray that has none either.
    if (saturation < 0.04) return 'gray';
    var best = 'zinc';
    var bestGap = 360.0;
    for (final name in grayNames) {
      final gap = _hueGap(hue, _hueOf(name));
      if (gap < bestGap) {
        bestGap = gap;
        best = name;
      }
    }
    return best;
  }

  static final Map<String, double> _hues = {};

  /// A swatch's own hue, taken from the middle of its ramp - the stop that
  /// is the color at its most itself.
  static double _hueOf(String name) => _hues.putIfAbsent(name, () {
    final color = Swatch.named[name]!.s500;
    return _hsl(color.r, color.g, color.b).$1;
  });

  /// The shortest way round the wheel between two hues, in degrees.
  static double _hueGap(double a, double b) {
    final gap = (a - b).abs() % 360;
    return gap > 180 ? 360 - gap : gap;
  }

  /// Hue in degrees, saturation and lightness in 0..1.
  static (double, double, double) _hsl(double r, double g, double b) {
    final max = math.max(r, math.max(g, b));
    final min = math.min(r, math.min(g, b));
    final lightness = (max + min) / 2;
    final delta = max - min;
    if (delta == 0) return (0, 0, lightness);

    final saturation = lightness > 0.5
        ? delta / (2 - max - min)
        : delta / (max + min);
    final double hue;
    if (max == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (max == g) {
      hue = 60 * ((b - r) / delta + 2);
    } else {
      hue = 60 * ((r - g) / delta + 4);
    }
    return ((hue + 360) % 360, saturation, lightness);
  }
}
