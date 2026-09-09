import 'package:tomeui/tomeui.dart';

import 'services/screen.dart';

/// The black the UI fades to when the screen goes to sleep, and comes back
/// out of.
///
/// Wrapped around every screen, above the navigator: sleep is not a route.
/// While the shade is down the UI under it is still there - the stack, the
/// focus, the place in the list - so a wake shows exactly what a sleep hid,
/// and the tickers under it are stopped so that a dark player is not also
/// a busy one. Once the shade has fully lifted it leaves the tree, so an
/// awake frame composites nothing extra.
///
/// On the device this runs in step with tempod's backlight ramp over the
/// same [ScreenService.fade]; the two read as one dimming.
class ScreenShade extends StatefulWidget {
  const ScreenShade({required this.screen, required this.child, super.key});

  final ScreenService screen;
  final Widget child;

  /// The shade itself, for a test that wants to know how far down it is.
  static const shadeKey = Key('ScreenShade.shade');

  @override
  State<ScreenShade> createState() => _ScreenShadeState();
}

class _ScreenShadeState extends State<ScreenShade>
    with SingleTickerProviderStateMixin {
  /// 0 is lifted, 1 is down.
  late final AnimationController _shade = AnimationController(
    vsync: this,
    duration: ScreenService.fade,
    value: widget.screen.value ? 0 : 1,
  );

  late final Animation<double> _opacity = CurvedAnimation(
    parent: _shade,
    curve: Curves.easeIn,
    reverseCurve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    widget.screen.addListener(_follow);
  }

  @override
  void didUpdateWidget(ScreenShade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.screen != oldWidget.screen) {
      oldWidget.screen.removeListener(_follow);
      widget.screen.addListener(_follow);
      _follow();
    }
  }

  @override
  void dispose() {
    widget.screen.removeListener(_follow);
    _shade.dispose();
    super.dispose();
  }

  void _follow() {
    if (widget.screen.value) {
      _shade.reverse();
    } else {
      _shade.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shade,
      // The dim rides under the sleep's shade: a lighter wash that comes
      // over the page as the warning before it goes dark.
      child: DimShade(screen: widget.screen, child: widget.child),
      builder: (context, child) {
        final lifted = _shade.isDismissed;
        final screen = TickerMode(enabled: widget.screen.value, child: child!);
        if (lifted) return screen;
        return Stack(
          textDirection: TextDirection.ltr,
          fit: StackFit.passthrough,
          children: [
            screen,
            Positioned.fill(
              child: IgnorePointer(
                child: FadeTransition(
                  key: ScreenShade.shadeKey,
                  opacity: _opacity,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The dim: a wash over the page while the screen is dimmed, the warning
/// before a sleep. On the device the backlight dims too; this is what the
/// emulator has, and it keeps the two looking alike. Fades in and out
/// over the screen's own fade, and leaves the tree when lifted.
class DimShade extends StatefulWidget {
  const DimShade({required this.screen, required this.child, super.key});

  final ScreenService screen;
  final Widget child;

  /// The wash, for a test that wants to know how far down it is.
  static const dimKey = Key('DimShade.dim');

  /// How much of the page the wash takes.
  static const double depth = 0.45;

  @override
  State<DimShade> createState() => _DimShadeState();
}

class _DimShadeState extends State<DimShade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dim = AnimationController(
    vsync: this,
    duration: ScreenService.fade,
    value: widget.screen.dimmed.value ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    widget.screen.dimmed.addListener(_follow);
  }

  @override
  void didUpdateWidget(DimShade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.screen != oldWidget.screen) {
      oldWidget.screen.dimmed.removeListener(_follow);
      widget.screen.dimmed.addListener(_follow);
      _follow();
    }
  }

  @override
  void dispose() {
    widget.screen.dimmed.removeListener(_follow);
    _dim.dispose();
    super.dispose();
  }

  void _follow() {
    if (widget.screen.dimmed.value) {
      _dim.forward();
    } else {
      _dim.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _dim,
      child: widget.child,
      builder: (context, child) {
        if (_dim.isDismissed) return child!;
        return Stack(
          textDirection: TextDirection.ltr,
          fit: StackFit.passthrough,
          children: [
            child!,
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  key: DimShade.dimKey,
                  opacity: _dim.value * DimShade.depth,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
