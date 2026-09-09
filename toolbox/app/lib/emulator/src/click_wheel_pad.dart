import 'dart:math' as math;

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'pressable.dart';
import 'skin.dart';
import 'wheel_motion.dart';

/// The wheel, drawn: the ring's four buttons around a center, a surface
/// that answers to being turned, and a light that shows it turning.
class ClickWheelPad extends StatefulWidget {
  const ClickWheelPad({
    required this.diameter,
    required this.motion,
    super.key,
  });

  final double diameter;
  static const centerFraction = 0.38;

  final WheelMotion motion;

  @override
  State<ClickWheelPad> createState() => _ClickWheelPadState();
}

class _ClickWheelPadState extends State<ClickWheelPad> {
  /// How far around the ring counts as one detent. The hardware's wheel
  /// reports about twenty to the turn; this is the same feel by hand.
  static const _detent = math.pi / 10;

  double? _lastAngle;
  double _travelled = 0;

  ClickWheelController get _wheel => widget.motion.wheel;

  void _panUpdate(Offset local) {
    final radius =
        (local - Offset(widget.diameter / 2, widget.diameter / 2)).distance;
    if (radius > widget.diameter / 2 ||
        radius < widget.diameter * ClickWheelPad.centerFraction / 2) {
      _lastAngle = null;
      _travelled = 0;
      return;
    }
    final angle = _angleAt(local);
    final last = _lastAngle;
    _lastAngle = angle;
    if (last == null) return;

    // Shortest way round, so crossing twelve o'clock isn't a whole turn.
    var delta = angle - last;
    if (delta > math.pi) delta -= math.pi * 2;
    if (delta < -math.pi) delta += math.pi * 2;

    _travelled += delta;
    while (_travelled.abs() >= _detent) {
      final direction = _travelled.isNegative ? -1 : 1;
      widget.motion.jog(direction);
      _travelled -= _detent * direction;
    }
  }

  double _angleAt(Offset local) {
    final center = widget.diameter / 2;
    return math.atan2(local.dy - center, local.dx - center);
  }

  @override
  Widget build(BuildContext context) {
    final skin = DeviceSkin.of(context);
    final size = widget.diameter;
    final center = size * ClickWheelPad.centerFraction;
    // The band is what is left of the wheel once the center button is out
    // of it; the printing sits on the middle of that, which is what the
    // eye reads as "on the wheel".
    final band = (size / 2 + center / 2) / 2;
    final glyph = size * 0.1;

    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: ClipPath(
              clipper: const WheelTrackClipper(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  _lastAngle = _angleAt(details.localPosition);
                  _travelled = 0;
                },
                onPanUpdate: (details) => _panUpdate(details.localPosition),
                onPanEnd: (_) => _lastAngle = null,
                onPanCancel: () => _lastAngle = null,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // The ring.
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: skin.wheel,
                        border: Border.all(color: skin.edge),
                      ),
                    ),
                    // The light that runs round it as it turns.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: WheelGlow(motion: widget.motion, diameter: size),
                      ),
                    ),
                    // The ring's four buttons, printed on the band between the
                    // wheel's inner and outer edges - the four the hardware has,
                    // wearing the pairs the hardware wears.
                    // Top and bottom carry a pair or a trio with a slash between
                    // the alternatives, and are printed smaller so the run stays
                    // the width of a single glyph on the sides.
                    _RingButton(
                      direction: const Offset(0, -1),
                      radius: band,
                      // Down and up rather than a tap: menu is a key that can be
                      // held, and the input counts the hold from these two.
                      onDown: _wheel.menuDown,
                      onUp: _wheel.menuUp,
                      glyphs: const [LucideIcons.undo2, LucideIcons.layoutGrid],
                      slashAfter: 0,
                      size: glyph * 0.8,
                    ),
                    _RingButton(
                      direction: const Offset(-1, 0),
                      radius: band,
                      onDown: () => _wheel.buttonDown(WheelButton.previous),
                      onUp: () => _wheel.buttonUp(WheelButton.previous),
                      glyphs: const [LucideIcons.skipBack],
                      size: glyph,
                    ),
                    _RingButton(
                      direction: const Offset(1, 0),
                      radius: band,
                      onDown: () => _wheel.buttonDown(WheelButton.next),
                      onUp: () => _wheel.buttonUp(WheelButton.next),
                      glyphs: const [LucideIcons.skipForward],
                      size: glyph,
                    ),
                    _RingButton(
                      direction: const Offset(0, 1),
                      radius: band,
                      onDown: () => _wheel.buttonDown(WheelButton.playPause),
                      onUp: () => _wheel.buttonUp(WheelButton.playPause),
                      glyphs: const [
                        LucideIcons.play,
                        LucideIcons.pause,
                        LucideIcons.square,
                      ],
                      slashAfter: 1,
                      size: glyph * 0.8,
                    ),
                  ],
                ),
              ),
            ),
          ),
          ClipOval(
            child:
                // The center.
                Pressable(
                  key: const ValueKey('wheel.center'),
                  // Down and up rather than a tap: every button of the ring
                  // has a long word now, and the input counts the hold.
                  onDown: () => _wheel.buttonDown(WheelButton.select),
                  onUp: () => _wheel.buttonUp(WheelButton.select),
                  builder: (context, wash) => Container(
                    width: center,
                    height: center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.alphaBlend(wash, skin.center),
                      border: Border.all(color: skin.edge),
                    ),
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

/// The same annulus clips both painting and pointer hit testing, including
/// the rotating glow's square layer. The center button has its own hit target.
class WheelTrackClipper extends CustomClipper<Path> {
  const WheelTrackClipper();

  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addOval(Offset.zero & size)
    ..addOval(
      Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: size.shortestSide * ClickWheelPad.centerFraction / 2,
      ),
    );

  @override
  bool shouldReclip(WheelTrackClipper oldClipper) => false;
}

/// The light on the wheel: a soft round glow sitting on the ring where the
/// wheel was last turned, gliding to each new detent and fading out when
/// the wheel goes quiet.
class WheelGlow extends StatelessWidget {
  const WheelGlow({required this.motion, required this.diameter, super.key});

  final WheelMotion motion;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final skin = DeviceSkin.of(context);
    // Wide enough to be a glow rather than a dot, and centerd on the middle
    // of the ring's band rather than its edge.
    final blob = diameter * 0.46;
    final radius = diameter * 0.34;

    return ListenableBuilder(
      listenable: motion,
      builder: (context, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: motion.angle),
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        builder: (context, angle, child) =>
            Transform.rotate(angle: angle, child: child),
        child: Align(
          alignment: Alignment.topCenter,
          child: Transform.translate(
            // Down from the ring's top edge onto the band itself.
            offset: Offset(0, diameter / 2 - radius - blob / 2),
            // The fade is the blob's alone, inside the turn: fading the
            // whole turned square instead asks the compositor for an
            // offscreen layer the size of the wheel, which some desktop
            // drivers hand back uncleared - the gray blocks around the
            // wheel at the larger zooms.
            child: AnimatedOpacity(
              opacity: motion.lit ? 1 : 0,
              duration: Duration(milliseconds: motion.lit ? 90 : 420),
              curve: Curves.easeOut,
              child: Container(
                width: blob,
                height: blob,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      skin.glow.withValues(alpha: 0.38),
                      skin.glow.withValues(alpha: 0.16),
                      skin.glow.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the ring's four: a hit target the size of the label it carries,
/// sitting on the ring rather than cutting it into quadrants.
/// One of the ring's four: the glyphs printed at that point of the compass,
/// sitting on the middle of the band rather than at either of its edges,
/// and pressable as far around them as the band is wide.
class _RingButton extends StatelessWidget {
  const _RingButton({
    required this.direction,
    required this.radius,
    required this.glyphs,
    required this.size,
    this.onDown,
    this.onUp,
    this.slashAfter,
  });

  /// Which way out of the center this slot sits, as a unit offset.
  final Offset direction;

  /// How far out: the middle of the band.
  final double radius;

  final List<IconData> glyphs;

  /// The index of the glyph a slash is printed after, where the run reads
  /// as alternatives - menu / home, play, pause / stop.
  final int? slashAfter;

  final double size;

  /// A tap, for a key whose grammar is presses; or down and up, for one
  /// whose grammar is holds.
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context) {
    final skin = DeviceSkin.of(context);

    return Transform.translate(
      offset: direction * radius,
      child: Pressable(
        // The wheel is the drag surface; a button on it is a tap.
        onDown: onDown,
        onUp: onUp,
        builder: (context, wash) => Container(
          padding: EdgeInsets.symmetric(
            horizontal: size * 0.45,
            vertical: size * 0.35,
          ),
          decoration: BoxDecoration(
            color: wash,
            borderRadius: BorderRadius.circular(size * 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: size * 0.34,
            children: [
              for (final (index, glyph) in glyphs.indexed) ...[
                Icon(glyph, size: size, color: skin.glyph),
                if (index == slashAfter)
                  Text(
                    '/',
                    style: TextStyle(
                      fontSize: size,
                      height: 1,
                      fontWeight: FontWeight.w300,
                      color: skin.glyph,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
