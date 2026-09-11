import 'dart:io' show FileSystemException;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable, Uint8List;
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:tomeui/tomeui.dart';

import 'services/services.dart';
import 'storage/places.dart';
import 'wallpaper_import.dart';
import 'wallpaper_palette.dart';

/// What a screen puts between itself and the [Wallpaper].
enum Backdrop {
  /// Nothing: the wallpaper is the screen's ground. Home, whose whole
  /// point is the picture - so this one stays clear whatever the
  /// surfaces are set to.
  clear,

  /// Nothing while surfaces are translucent, and the page color, solid,
  /// when they are not.
  ///
  /// A settings page: its cards are the ground and the wallpaper runs
  /// between them, which is a translucent idea. With [Glass.enabled] off
  /// nothing on the player is meant to show the picture through it, and
  /// a page whose gaps still did would be the one hole left in that.
  cards,

  /// A wash of the page color over the wallpaper: solid enough that what
  /// is on the screen reads while the page is the one in focus, and
  /// thinner - the wallpaper showing through - while it is a cover
  /// beside the one in focus. No blur anywhere: the panel's GPU has none
  /// to give.
  translucent,

  /// The page color, solid.
  opaque,
}

/// Where the wallpaper comes from: `wallpaper.<ext>` in the player's
/// config folder ([Places.config]), or the swirl this package bundles when
/// there is none there - and on the player and in the emulator, the swirl
/// is written there as `wallpaper.jpg` the first time, so the default is a
/// file the user can replace like any other.
///
/// It lived in the home as `~/.wallpaper.<ext>` until it moved in beside
/// the rest of what the player is set to; one left there is moved on the
/// first look ([_migrate]).
abstract final class WallpaperSource {
  /// The bundled default, until the user puts one of their own in the
  /// config folder.
  static const asset = AssetImage(
    'assets/wallpaper.jpg',
    package: 'tempo_core',
  );

  /// What the default is written as: the file it is.
  static const defaultExtension = 'jpg';

  /// The kinds of file looked for, in this order.
  static const extensions = ['png', 'jpg', 'jpeg', 'bmp', 'webp', 'gif'];

  /// What the [Wallpaper] paints.
  static final image = ValueNotifier<ImageProvider>(asset);

  /// The palettes the wallpaper on screen suggests, best first, and empty
  /// while the default is up. Read off the stored picture, which is panel
  /// sized, so working them out costs nothing worth measuring.
  static final palettes = ValueNotifier<List<WallpaperPalette>>(const []);

  /// Which of [palettes] the player is using, by position - Settings >
  /// Appearance > Wallpaper > Palette moves it.
  ///
  /// A picture usually suggests more than one honest reading of itself: the
  /// color that covers the most of it and the color that leaps out of it
  /// are often not the same, and which one a person wants under their menus
  /// is a matter of taste rather than arithmetic. So the palettes are
  /// offered in the order the arithmetic ranks them, and this says which
  /// was taken.
  static final paletteIndex = ValueNotifier<int>(0);

  /// The one a color slot set to follow the wallpaper takes its swatch
  /// from, or null where the picture suggested none.
  ///
  /// Clamped rather than checked: a stored index from a picture that
  /// suggested three palettes is meaningless against one that suggests
  /// two, and the best of them is a better answer than nothing.
  static WallpaperPalette? get palette {
    final all = palettes.value;
    if (all.isEmpty) return null;
    return all[paletteIndex.value.clamp(0, all.length - 1)];
  }

  /// Whether a config folder with no wallpaper gets the default written
  /// into it. The player and the emulator say yes; a test says nothing
  /// about the machine it runs on.
  static bool installDefault = false;

  /// How the picture is fitted to the panel.
  ///
  /// A wallpaper taken in through the picker is already cropped to the
  /// panel, so this changes nothing for one of those - it is for a picture
  /// put in the config folder by hand, which can be any shape at all.
  static final fit = ValueNotifier<BoxFit>(BoxFit.contain);

  /// The fit a stored name means. Anything else leaves it where it is.
  static BoxFit? fitNamed(Object? name) => switch (name) {
    'contain' => BoxFit.contain,
    'cover' => BoxFit.cover,
    'centre' || 'center' => BoxFit.none,
    _ => null,
  };

  /// The file a wallpaper would be, for [ext].
  static String pathFor(Places places, String ext) =>
      '${places.config}/wallpaper.$ext';

  /// Look in [places]'s config folder for a wallpaper and show it; failing
  /// that, show the default and, if [installDefault], write it there.
  static Future<void> load(Places places) async {
    for (final ext in extensions) {
      final file = places.fileSystem.file(pathFor(places, ext));
      try {
        if (!file.existsSync()) continue;
        final bytes = file.readAsBytesSync();
        image.value = MemoryImage(bytes);
        palettes.value = Wallpapers.preview(bytes).palettes;
        return;
      } on FileSystemException catch (error) {
        debugPrint('wallpaper: ${file.path}: ${error.message}');
      }
    }
    image.value = asset;
    palettes.value = const [];
    if (!installDefault) return;
    try {
      final bytes = await _defaultBytes();
      final file = places.fileSystem.file(pathFor(places, defaultExtension));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
    } on Object catch (error) {
      debugPrint('wallpaper: could not write the default: $error');
    }
  }

  /// Take the picture at [source] in as the wallpaper.
  ///
  /// Cropped and scaled to the panel on the way ([Wallpapers.take]) and
  /// written into the config folder as our own file, so what is painted is
  /// panel-sized and outlives the picture it came from - the card can be
  /// pulled, or the original deleted, and the wallpaper is still there.
  ///
  /// False where the file could not be read or is not a picture; nothing
  /// is written and what was up stays up.
  static Future<bool> adopt(Places places, String source) async {
    final Uint8List bytes;
    try {
      bytes = places.fileSystem.file(source).readAsBytesSync();
    } on FileSystemException catch (error) {
      debugPrint('wallpaper: $source: ${error.message}');
      return false;
    }
    final taken = Wallpapers.take(bytes);
    if (taken == null) return false;

    try {
      final file = places.fileSystem.file(
        pathFor(places, Wallpapers.storedExtension),
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(taken.bytes);
      // One wallpaper, one file: a picture left behind under another
      // extension would be found first by the next boot's search.
      for (final ext in extensions) {
        if (ext == Wallpapers.storedExtension) continue;
        final stale = places.fileSystem.file(pathFor(places, ext));
        if (stale.existsSync()) stale.deleteSync();
      }
    } on FileSystemException catch (error) {
      debugPrint('wallpaper: could not write it: ${error.message}');
      return false;
    }

    image.value = MemoryImage(taken.bytes);
    palettes.value = taken.palettes;
    return true;
  }

  static Future<Uint8List> _defaultBytes() async {
    // The bundle names a package's asset by its package from outside and
    // by its own path from inside; the app is outside, this package's
    // tests are inside.
    ByteData data;
    try {
      data = await rootBundle.load('packages/tempo_core/assets/wallpaper.jpg');
    } on FlutterError {
      data = await rootBundle.load('assets/wallpaper.jpg');
    }
    return data.buffer.asUint8List();
  }
}

/// The user's wallpaper, under everything: [WallpaperSource.image], full
/// frame on the theme's dark neutral.
///
/// One of these sits under the navigator, so it is always painted and any
/// screen can see through to it as far as its [Backdrop] lets it. It is
/// also what asks [WallpaperSource] to look, once it knows whose home to
/// look in.
class Wallpaper extends StatefulWidget {
  const Wallpaper({super.key});

  @override
  State<Wallpaper> createState() => _WallpaperState();
}

class _WallpaperState extends State<Wallpaper> {
  ValueListenable<Places>? _places;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final places = PlayerServicesScope.of(context).places;
    if (identical(places, _places)) return;
    _places?.removeListener(_look);
    _places = places..addListener(_look);
    _look();
  }

  @override
  void dispose() {
    _places?.removeListener(_look);
    super.dispose();
  }

  /// Look after the frame: this may be the middle of a build, and every
  /// other wallpaper on screen rebuilds on what is found.
  void _look() {
    final places = _places!.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) WallpaperSource.load(places);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      // The theme's dark neutral, not black: the ground a wallpaper that
      // does not fill the panel is seen against, and the same surface the
      // pages and the glass are made of.
      color: ThemeProvider.of(context).palette.surface,
      child: ValueListenableBuilder(
        valueListenable: WallpaperSource.image,
        builder: (context, image, _) => ValueListenableBuilder(
          valueListenable: WallpaperSource.fit,
          builder: (context, fit, _) => Image(image: image, fit: fit),
        ),
      ),
    );
  }
}

/// A slab of glass: the surface color, most of the way to solid, over
/// whatever is behind it, with a rounded edge and the faintest rim. What
/// the dock is made of, and what the bar becomes while the dock is up.
/// Tinted, not blurred: nothing on the player blurs.
class Glass extends StatelessWidget {
  const Glass({required this.child, this.radius, super.key});

  final Widget child;

  /// The corners, or the theme's medium radius.
  final BorderRadius? radius;

  /// How much of the surface color the glass carries.
  static const double tint = 0.75;

  /// And a surface out in the flow, beside the cover in the middle: more
  /// of the picture through it, because the flow is the picture's moment.
  static const double faint = 0.45;

  /// Whether the dock and the bar are glass at all. Off, they are the page
  /// color: the wallpaper stops short of the chrome.
  static final enabled = ValueNotifier<bool>(true);

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final radius = this.radius ?? theme.radii.medium;
    // Listened to, not merely read: a setting the eye is on while the
    // hand moves it has to answer that frame. Read from build without a
    // listener, this repainted only when something else happened to - a
    // theme change, a route, the clock - which is a setting that appears
    // to work sometimes.
    return ListenableBuilder(
      listenable: Backdropped.changes,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: Backdropped.surfaceOf(theme.palette),
          borderRadius: radius,
          border: Border.all(
            color: theme.palette.divider.withValues(alpha: 0.6),
            width: theme.strokes.hairline,
          ),
        ),
        child: child,
      ),
      child: child,
    );
  }
}

/// How much in focus the cover a page is on is: 1 on stage and under the
/// dock's box, falling to 0 as it stands beside the one that is. The
/// stage sets it over each app; a page outside the stage (a test that
/// mounts one bare) is in focus.
class CoverFocus extends InheritedWidget {
  const CoverFocus({required this.focus, required super.child, super.key});

  final double focus;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CoverFocus>()?.focus ?? 1;

  @override
  bool updateShouldNotify(CoverFocus oldWidget) => focus != oldWidget.focus;
}

/// Puts [backdrop] under [child].
///
/// A page paints no wallpaper of its own: the shell's is under everything,
/// seen sharp through a clear page, and through a translucent page's wash
/// of the page color - [solid] while the page is in focus, [faint] while
/// it is a cover beside the one that is, following the wheel between
/// ([CoverFocus]). An opaque page paints the page color itself. Which of
/// these a page is goes out with its chrome ([BarChrome.backdrop]).
class Backdropped extends StatelessWidget {
  const Backdropped({required this.backdrop, required this.child, super.key});

  final Backdrop backdrop;
  final Widget child;

  /// The tint the player ships at, 0..1.
  static const double solid = 0.88;

  /// The bottom of the slider's range: a surface this far down is nearly
  /// the page behind it, which is as flat as the UI is allowed to get.
  static const double faint = 0.4;

  /// What Settings > Appearance > Page Tint is set to, 0..1.
  ///
  /// A *tone*, not a transparency: how far a surface stands off the page
  /// behind it. See [tone].
  static final tint = ValueNotifier<double>(solid);

  /// Both settings at once: what everything drawn over the wallpaper
  /// watches, since either one changes what it is.
  static final changes = Listenable.merge([Glass.enabled, tint]);

  /// The color a surface is drawn in, at the tint it is set to.
  ///
  /// Page Tint says how much of the surface color you get, which is a
  /// question about shade and not about transparency. Turned down, a card
  /// is nearly the page it sits on; turned up, it is a clear step off it.
  /// Either way it is the same card, equally solid or equally glass:
  /// whether the picture comes *through* it is [Glass.enabled]'s
  /// question, and the only one it is.
  static Color tone(Palette palette) {
    // Literally what the setting says: at the top of the range a surface
    // is the whole of the page color, and at the bottom it is the page
    // behind it. What is left marking a card there is its ring, which is
    // as flat as the UI is allowed to get.
    final at = ((tint.value - faint) / (1 - faint)).clamp(0.0, 1.0);
    return Color.lerp(palette.background, palette.surface, at)!;
  }

  /// How opaque a surface is: glass, or solid.
  ///
  /// [focus] is how much in focus the cover it is on is - out in the
  /// flow, a cover beside the one in the middle lets more of the picture
  /// through, because the flow is the picture's moment.
  static double opacity({double focus = 1}) =>
      Glass.enabled.value ? lerpDouble(Glass.faint, Glass.tint, focus)! : 1;

  /// The whole dress of a surface over the wallpaper: [tone], at the
  /// [opacity] the surfaces are set to.
  static Color surfaceOf(Palette palette, {double focus = 1}) =>
      tone(palette).withValues(alpha: opacity(focus: focus));

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    // A clear page is the wallpaper, and the wallpaper has no edge. Only
    // a page that is genuinely one surface takes a ground, and a hairline
    // around it.
    if (backdrop == Backdrop.clear) return child;
    return ListenableBuilder(
      listenable: changes,
      // Opaque means opaque: a screen that is one surface filling the
      // panel is not a pane of glass, whatever the surfaces are set to.
      // It still takes its shade from the tint, being a surface.
      builder: (context, _) => ColoredBox(
        color: tone(theme.palette),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.palette.divider.withValues(alpha: 0.5),
              width: theme.strokes.hairline,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
