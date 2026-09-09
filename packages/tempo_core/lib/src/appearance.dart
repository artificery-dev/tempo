import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:tomeui/tomeui.dart';

import 'scale.dart';
import 'solar.dart';
import 'wallpaper.dart';

/// Light, dark, or the sun.
enum AppearanceMode {
  /// Light between sunrise and sunset, dark the rest of the day, worked
  /// out for wherever the player is set to be ([Appearance.place]).
  ///
  /// With no place to ask about - the time zone still at UTC, or a rootfs
  /// with no zone table - it falls back to what the machine around the UI
  /// is wearing ([Appearance.systemBrightness]), which on a desk is the
  /// desktop's own light and on the player is simply where it started.
  auto,

  light,
  dark,
}

/// How the player's UI is dressed: in what light, and at what size.
///
/// [mode] and [scale] are Settings > Appearance's, moved by the bindings
/// in `PlayerSettings`. [place] follows Settings > Time & Language > Time
/// Zone, which is where the sun's timetable comes from.
abstract final class Appearance {
  /// What was chosen. Dark to begin with, because a player in a pocket at
  /// night is the case to design for.
  static final mode = ValueNotifier<AppearanceMode>(AppearanceMode.dark);

  /// How large the UI is drawn.
  static final scale = ValueNotifier<UiScale>(UiScale.regular);

  /// The three swatches the UI is mixed from, by name - Settings >
  /// Appearance > Colors moves these. Names rather than swatches because a
  /// settings file holds "sky", not a ramp of twelve colors; [Swatch.byName]
  /// turns one back into the other.
  static final primary = ValueNotifier<String>(defaultPrimary);
  static final accent = ValueNotifier<String>(defaultAccent);
  static final neutral = ValueNotifier<String>(defaultNeutral);

  /// What the player is mixed from out of the box, and what Reset Colors
  /// puts back: Auto, following the wallpaper palette.
  static const defaultPrimary = fromWallpaper;
  static const defaultAccent = fromWallpaper;
  static const defaultNeutral = fromWallpaper;

  /// The value a color slot holds when it follows the wallpaper rather
  /// than naming a swatch of its own.
  static const fromWallpaper = 'wallpaper';

  /// The swatch a slot comes to: the one it names, or - where it is set to
  /// [fromWallpaper] - the one the picture on screen suggests for that
  /// role.
  ///
  /// Null where the name is not a swatch this build has and the wallpaper
  /// has nothing to say either; the theme takes Tome's own default for the
  /// role, which is what an unreadable setting should come to.
  static Swatch? swatchFor(String name, String role) {
    if (name != fromWallpaper) return Swatch.byName(name);
    return Swatch.byName(WallpaperSource.palette?[role]);
  }

  /// Back to the three above.
  static void resetColors() {
    primary.value = defaultPrimary;
    accent.value = defaultAccent;
    neutral.value = defaultNeutral;
  }

  /// Where the player thinks it is, for [AppearanceMode.auto]'s sake:
  /// the place its time zone stands for. Null until a zone with a place
  /// behind it is chosen.
  static final place = ValueNotifier<SolarPlace?>(null);

  /// What the machine around the UI is wearing, for whoever is in a
  /// position to know - the emulator, which can see a desktop. Read only
  /// as [AppearanceMode.auto]'s fallback, where there is no place.
  static final systemBrightness = ValueNotifier<Brightness>(Brightness.dark);

  /// The answer: [mode] resolved against the sun. Listen to this rather
  /// than to any of the parts.
  static final ValueListenable<Brightness> brightness = _install();

  /// The whole answer: the theme [brightness] and [scale] come to. What the
  /// player's app is dressed in.
  static final ValueListenable<Theme> theme = _resolveTheme();

  /// [theme] as the player's chrome is drawn: the same light and the same
  /// colors, at the fixed [chromeScale]. For the parts that lay themselves
  /// out against the chrome without being inside it - how much of the panel
  /// the bar and the dock take.
  static Theme chromeOf(Theme theme) =>
      themeFor(theme.palette.brightness, scale: chromeScale);

  /// The theme a brightness comes to, at [scale] - the current one unless
  /// told otherwise.
  static Theme themeFor(Brightness brightness, {UiScale? scale}) =>
      (scale ?? Appearance.scale.value).theme(
        brightness,
        primary: swatchFor(Appearance.primary.value, 'primary'),
        accent: swatchFor(Appearance.accent.value, 'accent'),
        neutral: swatchFor(Appearance.neutral.value, 'neutral'),
      );

  /// When the light next changes of its own accord, and null when it does
  /// not: any mode but [AppearanceMode.auto], or auto with no place. What
  /// the player would put on a screen that says what Auto is doing.
  static DateTime? get nextChange {
    if (mode.value != AppearanceMode.auto) return null;
    final where = place.value;
    if (where == null || !where.isValid) return null;
    return Solar.nextChange(where, DateTime.now());
  }

  static Brightness get _current => switch (mode.value) {
    AppearanceMode.auto => _daylight,
    AppearanceMode.light => Brightness.light,
    AppearanceMode.dark => Brightness.dark,
  };

  static Brightness get _daylight {
    final where = place.value;
    // Nowhere to stand: the sun cannot be asked, so the machine is.
    if (where == null || !where.isValid) return systemBrightness.value;
    return Solar.isDaylight(where, DateTime.now())
        ? Brightness.light
        : Brightness.dark;
  }

  static final _resolved = ValueNotifier(_current);

  static ValueListenable<Brightness> _install() {
    mode.addListener(_update);
    place.addListener(_update);
    systemBrightness.addListener(_update);
    _arm();
    return _resolved;
  }

  static void _update() {
    _resolved.value = _current;
    _arm();
  }

  /// The clock that turns the light over at sunrise and at sunset.
  ///
  /// One timer, set to the next crossing rather than a poll: the sun keeps
  /// a timetable, so there is no reason to keep asking it what time it is.
  static Timer? _sun;

  /// How long to wait when there is no crossing to wait for: a polar
  /// summer or winter, where the next one may be weeks off. Long enough
  /// not to be a poll, short enough to catch the day it starts again.
  static const _polarRecheck = Duration(hours: 6);

  static void _arm() {
    _sun?.cancel();
    _sun = null;
    if (_underTest) return;
    if (mode.value != AppearanceMode.auto) return;
    final where = place.value;
    if (where == null || !where.isValid) return;

    final now = DateTime.now();
    final next = Solar.nextChange(where, now);
    // A second past the crossing, so the recomputation lands on the far
    // side of it rather than exactly on the line.
    final wait = next == null
        ? _polarRecheck
        : next.difference(now) + const Duration(seconds: 1);
    _sun = Timer(wait.isNegative ? const Duration(seconds: 1) : wait, _update);
  }

  /// The test harness runs its own clock and fails a test that leaves a
  /// timer pending, so the sun's is not started under it. The resolution
  /// itself is not conditional: a test can move [place] or the clock and
  /// read [brightness] as ever.
  static final bool _underTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  static ValueNotifier<Theme> _resolveTheme() {
    final resolved = ValueNotifier(themeFor(brightness.value));
    void update() => resolved.value = themeFor(brightness.value);
    brightness.addListener(update);
    scale.addListener(update);
    for (final swatch in [primary, accent, neutral]) {
      swatch.addListener(update);
    }
    // A slot set to follow the wallpaper moves when the wallpaper does,
    // and when a different one of its palettes is taken.
    WallpaperSource.palettes.addListener(update);
    WallpaperSource.paletteIndex.addListener(update);
    return resolved;
  }
}

/// Draws [child] at a fixed [UiScale], whatever the player is set to.
///
/// Both halves of it. The scale is not only what [UiScale.of] answers - it
/// is also where the theme's typography, spacing, sizes and strokes come
/// from - so pinning a subtree means giving it a theme built at that scale
/// as well as a scope saying so. The light and the colors are the ambient
/// theme's, and still move with the setting.
class FixedScale extends StatelessWidget {
  const FixedScale({required this.scale, required this.child, super.key});

  final UiScale scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    if (Appearance.scale.value == scale) return child;
    return ThemeProvider(
      theme: Appearance.themeFor(theme.palette.brightness, scale: scale),
      child: UiScaleScope(scale: scale, child: child),
    );
  }
}
