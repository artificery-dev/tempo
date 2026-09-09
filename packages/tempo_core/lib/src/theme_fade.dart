import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:tomeui/tomeui.dart';

/// The light going up or down as a fade rather than a cut.
///
/// A theme cannot be interpolated. [Palette.brightness] is one thing or the
/// other, and no color in the UI is stored as a value to lerp: every one of
/// them is *resolved* against that brightness at build time, by the widget
/// drawing it. There is no halfway palette to hand anybody.
///
/// So the change is animated where it can be - on the glass. The frame as
/// it stood is held as a picture, the new theme is drawn underneath it, and
/// the picture fades away. Nothing in the tree knows a transition is
/// happening: the app rebuilds once, as it always did, and what softens the
/// change is a layer over the top of it.
///
/// The held frame is a still, so anything moving underneath it is frozen
/// for the length of the fade. At [Motion.standard] that is not long enough
/// to read as a stutter, and a theme change is not a moment anything else
/// should be moving anyway.
class ThemeFade extends StatefulWidget {
  const ThemeFade({
    required this.brightness,
    required this.duration,
    required this.curve,
    required this.child,
    super.key,
  });

  /// What the light is now. A change to this is what starts a fade.
  final Brightness brightness;

  final Duration duration;
  final Curve curve;

  final Widget child;

  /// The layer the held frame is drawn in, for tests.
  static const heldKey = Key('ThemeFade.held');

  @override
  State<ThemeFade> createState() => _ThemeFadeState();
}

class _ThemeFadeState extends State<ThemeFade>
    with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();

  /// Built here rather than lazily: a fade that never runs would otherwise
  /// have its controller created by [dispose] calling into it, and making a
  /// ticker against an element that is already deactivated is an error.
  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_done);
  }

  /// The frame as it was before the light changed, held until it has faded.
  ui.Image? _before;

  @override
  void didUpdateWidget(ThemeFade old) {
    super.didUpdateWidget(old);
    _fade.duration = widget.duration;
    if (old.brightness == widget.brightness) return;
    // Taken here rather than after the frame: this runs while the tree is
    // being rebuilt for the new theme and before any of it is painted, so
    // the boundary is still holding the last frame drawn in the old one -
    // which is exactly the picture wanted.
    _hold(_capture());
  }

  ui.Image? _capture() {
    final object = _boundary.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary || !object.hasSize) return null;
    try {
      return object.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } on Object catch (error) {
      // A host with no way to rasterise a layer - and a cut instead of a
      // fade, which is what there was before this widget.
      debugPrint('theme: cannot hold the frame: $error');
      return null;
    }
  }

  void _hold(ui.Image? frame) {
    if (frame == null) return;
    setState(() {
      _before?.dispose();
      _before = frame;
    });
    _fade.forward(from: 0);
  }

  void _done(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _before?.dispose();
      _before = null;
    });
  }

  @override
  void dispose() {
    _before?.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final before = _before;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        RepaintBoundary(key: _boundary, child: widget.child),
        if (before != null)
          Positioned.fill(
            key: ThemeFade.heldKey,
            // A still over a live tree: it must not take the wheel's words
            // or a pointer, and it must not be read out either.
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: Tween(begin: 1.0, end: 0.0).animate(
                    CurvedAnimation(parent: _fade, curve: widget.curve),
                  ),
                  child: RawImage(image: before, fit: BoxFit.fill),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
