import 'package:tomeui/tomeui.dart';

/// What the device is made of, in the light it is being looked at in.
///
/// A silver player in daylight and a black one at night: the same object,
/// dressed off the theme's neutral swatch so the emulator's body belongs to
/// whatever the desktop is wearing.
@immutable
class DeviceSkin {
  const DeviceSkin({
    required this.body,
    required this.edge,
    required this.wheel,
    required this.center,
    required this.key,
    required this.glyph,
    required this.bezel,
    required this.glow,
    required this.wash,
  });

  factory DeviceSkin.of(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final neutral = theme.palette.neutral;
    final light = theme.palette.brightness == Brightness.light;

    return DeviceSkin(
      body: light ? neutral.s100 : neutral.s800,
      edge: light ? neutral.s300 : neutral.s700,
      wheel: light ? neutral.s50 : neutral.s900,
      center: light ? neutral.s0 : neutral.s800,
      key: light ? neutral.s200 : neutral.s700,
      glyph: light ? neutral.s500 : neutral.s400,
      // The screen's surround is black plastic in both lights - it is the
      // one part of the device that isn't painted.
      bezel: const Color(0xFF101014),
      glow: theme.palette.primary.s400,
      wash: light ? neutral.s950 : neutral.s0,
    );
  }

  /// The plastic, and the line around it.
  final Color body;
  final Color edge;

  /// The wheel's face and the button in the middle of it.
  final Color wheel;
  final Color center;

  /// The keys on the edges, and what is printed on them.
  final Color key;
  final Color glyph;

  final Color bezel;

  /// The light that runs round the wheel as it turns.
  final Color glow;

  /// Laid over a key to show a pointer on it: the foreground color, at the
  /// alphas [pressable] uses.
  final Color wash;

  Color washAt({required bool hovered, required bool pressed}) =>
      wash.withValues(alpha: pressed ? 0.14 : (hovered ? 0.06 : 0));
}
