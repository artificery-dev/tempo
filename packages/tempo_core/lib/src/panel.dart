import 'dart:math' as math;

import 'package:tomeui/tomeui.dart';

/// The player's screen, as the app's fixed frame of reference.
///
/// Every screen in Tempo is laid out for this panel and nothing else, so
/// the numbers live here once rather than being inferred from whatever
/// surface the app happens to be running on.
abstract final class Panel {
  /// The addressable pixels: the mode the gc9503v driver sets and the size
  /// of the framebuffer the display controller scans out.
  static const Size pixels = Size(480, 360);

  /// The physical size, from `width_mm`/`height_mm` in
  /// platform/kernel/linux/drivers/gpu/drm/panel/panel-gc9503v.c - a 2.3" diagonal, about
  /// the length of a thumb. The host window is cut to these millimeters.
  static const Size millimeters = Size(46, 35);

  /// The device pixel ratio every screen is laid out at.
  ///
  /// flutter-pi derives its own from the DRM connector's physical size as
  /// `(10 * width) / (width_mm * 38)`, which for this panel is 4800/1748;
  /// the device's framebuffer agrees, a 44dp `WheelList` row measuring
  /// 120.8 panel pixels. Pinning the same value here instead of trusting
  /// the embedder is what lets a desktop host reproduce the player exactly
  /// - and makes the ratio ours to choose: change this one number and the
  /// player and the host move together.
  static const double devicePixelRatio = 4800 / 1748; // 2.746

  /// The logical canvas the panel's pixels come to: 174.8 x 131.1dp.
  static Size get logicalSize => pixels / devicePixelRatio;
}

/// Puts [child] on a canvas of exactly [Panel] - the player's pixels, the
/// player's pixel ratio - whatever surface it is really being displayed on.
///
/// With no [size] the panel takes the whole surface, which on the player is
/// the identity: the panel *is* the surface, so the child is laid out and
/// rasterized untouched.
///
/// A host that draws its own body - the emulator - names a [size]
/// instead, and the panel is drawn at exactly that
/// and centerd on whatever room is left over. It is pinned there: a bigger
/// window gives the panel more field, not more panel, because a player's
/// screen doesn't grow either.
class PanelSurface extends StatelessWidget {
  const PanelSurface({required this.child, this.size, super.key});

  final Widget child;

  /// How large to draw the panel, in the host's logical pixels. Null fills
  /// the surface.
  final Size? size;

  /// Below this much difference from the surface's own size the scale is
  /// dropped rather than applied: on the player it would be a
  /// floating-point residue, and a transform of 1.0000001 buys nothing but
  /// text off the pixel grid.
  static const _identityTolerance = 0.002;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final logical = Panel.logicalSize;
    final drawn = size ?? media.size;
    final scale = math.min(
      drawn.width / logical.width,
      drawn.height / logical.height,
    );

    final Widget panel = MediaQuery(
      // The panel's own metrics, not the host's: a desktop's text scaling
      // factor or window insets must not reach a screen that will never
      // see either.
      data: media.copyWith(
        size: logical,
        devicePixelRatio: Panel.devicePixelRatio,
        textScaler: TextScaler.noScaling,
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
      ),
      child: SizedBox.fromSize(size: logical, child: child),
    );

    if ((scale - 1).abs() < _identityTolerance) return Center(child: panel);

    return Center(
      child: SizedBox.fromSize(
        // Tight, so the fit below has something to fit *to*: a FittedBox
        // with room to spare takes its child's size and scales by nothing.
        size: logical * scale,
        child: FittedBox(
          fit: BoxFit.contain,
          clipBehavior: Clip.hardEdge,
          child: panel,
        ),
      ),
    );
  }
}
