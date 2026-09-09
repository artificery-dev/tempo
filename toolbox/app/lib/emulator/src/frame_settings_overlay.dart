import 'dart:ui' show ImageFilter;

import 'package:tomeui/tomeui.dart';

/// Kept in the tree so controls retain state while the glass fades in and out.
/// The caller clips this widget to the player frame, including its blur.
class FrameSettingsOverlay extends StatelessWidget {
  const FrameSettingsOverlay({
    required this.visible,
    required this.child,
    super.key,
  });
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: visible ? 1 : 0),
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeInOut,
    child: child,
    builder: (context, opacity, child) => Offstage(
      offstage: opacity == 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 8 * opacity,
                sigmaY: 8 * opacity,
              ),
              child: Opacity(
                opacity: opacity,
                child: ColoredBox(
                  color: ThemeProvider.of(
                    context,
                  ).palette.background.withValues(alpha: .8),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
