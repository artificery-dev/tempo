import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tomeui/tomeui.dart';

import 'panel.dart';
import 'wallpaper_palette.dart';

/// A picture as the picker shows it: the colors it suggests, and a small
/// square of it to put beside its name.
@immutable
class WallpaperPreview {
  const WallpaperPreview({required this.palettes, this.thumbnail});

  /// What the picture is made of, best first.
  final List<WallpaperPalette> palettes;

  /// A small square of the middle of it, as a PNG. Null where the picture
  /// could not be read at all.
  final Uint8List? thumbnail;

  /// What a picture that would not decode comes to: asked and answered.
  static const none = WallpaperPreview(palettes: []);
}

/// A wallpaper taken in: the picture as it will be stored, and the palettes
/// it suggests.
@immutable
class WallpaperImport {
  const WallpaperImport({required this.bytes, required this.palettes});

  /// The re-encoded picture, cropped and scaled to the panel.
  final Uint8List bytes;

  /// What the picture is made of, best first. Never empty for a picture
  /// that decoded at all.
  final List<WallpaperPalette> palettes;
}

/// Taking a picture in as the wallpaper.
///
/// A wallpaper is copied rather than referred to, and it is copied *small*.
/// Three things fall out of that, and all three matter on a player:
///
///  * the panel is 480x360, so a twelve-megapixel photograph is decoded and
///    scaled once, here, instead of on every frame that paints it;
///  * the file the user picked can be deleted, or the card pulled, and the
///    wallpaper is still there, because what was kept is ours;
///  * the palettes are read off the same pixels, so choosing a picture and
///    knowing what colors it suggests is one pass over one image.
///
/// What is stored is scaled so it *covers* the panel - big enough that
/// neither side comes up short - and then trimmed only where that leaves
/// it wildly out of shape ([overflow]). Not cropped to the panel exactly,
/// because Settings > Appearance > Wallpaper > Fit is a choice about how
/// the picture meets the panel, and a picture already cut to the panel
/// has no choice left in it: contain, cover and center would all draw the
/// same rectangle. Scaling is what makes it cheap to paint; the crop was
/// never the part that did.
abstract final class Wallpapers {
  /// What a stored wallpaper is written as. PNG: lossless, so a picture
  /// already scaled to the panel is not degraded again each time it is
  /// re-adopted, and small enough at this size to be cheap.
  static const storedExtension = 'png';

  /// How big a picker thumbnail is, square, in pixels.
  ///
  /// A row is about forty points tall and the panel draws close to three
  /// pixels to the point, so this is a little over what a row can show -
  /// enough that the square is not soft, small enough that a folder of
  /// them is a few megabytes rather than a few hundred.
  static const thumbSize = 96;

  /// The size a wallpaper is kept at: the panel's own pixels. Anything
  /// larger is detail the panel cannot show.
  static int get width => Panel.pixels.width.round();

  static int get height => Panel.pixels.height.round();

  /// How far past the panel a stored picture may run on its long side,
  /// as a multiple of it, before the rest is trimmed off evenly.
  ///
  /// A picture two panels wide is a picture the panel can still make
  /// something of - Cover crops it, Contain letterboxes it, and either is
  /// a reasonable thing to want. A panorama eight panels wide is a file
  /// to carry around for a strip nobody can see, so it is cut down.
  static const double overflow = 2;

  /// Decode [bytes], crop and scale them to the panel, and read the
  /// palettes off the result.
  ///
  /// Null where the bytes are not a picture this build can read - a caller
  /// says so rather than writing a broken wallpaper.
  ///
  /// A decoder handed something that is not a picture does not always
  /// answer politely: a truncated or corrupt file can run it off the end of
  /// its own buffer. Everything it throws is a refusal here, because from
  /// the outside "this is not a picture" is the whole of the answer.
  static WallpaperImport? take(Uint8List bytes, {int palettes = 3}) {
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } on Object catch (error) {
      debugPrint('wallpaper: could not read the picture: $error');
      return null;
    }
    if (decoded == null) return null;
    // Whatever the camera said about which way up it was.
    final fitted = stored(img.bakeOrientation(decoded));
    return WallpaperImport(
      bytes: img.encodePng(fitted),
      palettes: WallpaperPalettes.fromPixels(
        fitted.getBytes(order: img.ChannelOrder.rgba),
        width: fitted.width,
        height: fitted.height,
        count: palettes,
      ),
    );
  }

  /// What the picker shows for [bytes]: the palettes, and a thumbnail.
  ///
  /// Cheaper than [take] on purpose: a folder of wallpapers is a folder of
  /// pictures to decode, and only the one that is chosen is worth cropping
  /// to the panel and writing. Both come out of the one decode, because
  /// decoding is the expensive half and doing it twice for the same row
  /// would be doing it twice for nothing.
  static WallpaperPreview preview(Uint8List bytes, {int count = 3}) {
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } on Object catch (error) {
      debugPrint('wallpaper: could not read the picture: $error');
      return WallpaperPreview.none;
    }
    if (decoded == null) return WallpaperPreview.none;
    final upright = img.bakeOrientation(decoded);
    // Down to the sampling width before reading: the hues of a picture
    // survive being shrunk, and this is the whole cost of a row.
    final small = upright.width > WallpaperPalettes.sampleWidth
        ? img.copyResize(
            upright,
            width: WallpaperPalettes.sampleWidth,
            interpolation: img.Interpolation.average,
          )
        : upright;
    return WallpaperPreview(
      palettes: WallpaperPalettes.fromPixels(
        small.getBytes(order: img.ChannelOrder.rgba),
        width: small.width,
        height: small.height,
        count: count,
      ),
      thumbnail: img.encodePng(square(upright)),
    );
  }

  /// The middle of [source] as a [thumbSize] square.
  ///
  /// A square, and cropped rather than squashed: a row of thumbnails of
  /// one size reads as a column, and a portrait squeezed into a square is
  /// a picture nobody would recognise as theirs.
  static img.Image square(img.Image source) {
    if (source.width <= 0 || source.height <= 0) return source;
    final side = math.min(source.width, source.height);
    final middle = img.copyCrop(
      source,
      x: (source.width - side) ~/ 2,
      y: (source.height - side) ~/ 2,
      width: side,
      height: side,
    );
    if (side == thumbSize) return middle;
    return img.copyResize(
      middle,
      width: thumbSize,
      height: thumbSize,
      interpolation: img.Interpolation.average,
    );
  }

  /// [source] as it will be kept: scaled so it covers the panel, and cut
  /// back to [overflow] panels on either side if it runs further than
  /// that.
  ///
  /// Whatever is left of the picture's own shape is left in it, which is
  /// what gives Fit something to decide. A picture that is already the
  /// panel's shape comes out exactly the panel's size, which is the
  /// common case and the cheapest one.
  static img.Image stored(img.Image source) {
    if (source.width <= 0 || source.height <= 0) return source;
    // Scale by whichever side needs the most to reach the panel, so
    // neither ends up short of it.
    final scale = math.max(width / source.width, height / source.height);
    final scaled = img.copyResize(
      source,
      width: math.max(width, (source.width * scale).ceil()),
      height: math.max(height, (source.height * scale).ceil()),
      interpolation: img.Interpolation.average,
    );
    final limit = (width * overflow).round();
    final tall = (height * overflow).round();
    if (scaled.width <= limit && scaled.height <= tall) return scaled;
    final keptWidth = math.min(scaled.width, limit);
    final keptHeight = math.min(scaled.height, tall);
    return img.copyCrop(
      scaled,
      x: ((scaled.width - keptWidth) / 2).round(),
      y: ((scaled.height - keptHeight) / 2).round(),
      width: keptWidth,
      height: keptHeight,
    );
  }
}
