import 'package:tomeui/tomeui.dart';

/// The way one page gives way to the next inside an app: the click-wheel
/// players' slide. The new page comes in from the right as the old one
/// leaves to the left, edge to edge, so that two translucent pages are
/// never over each other - a fade would show the wallpaper through both
/// washes at once. Back is the same slide the other way.
class PanelRoute<T> extends PageRouteBuilder<T> {
  PanelRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: motion.standard,
        reverseTransitionDuration: motion.standard,
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: _slide,
      );

  /// The system's motion tokens: the standard duration, the move curve.
  static const motion = Motion();

  static Widget _slide(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // The same easing on the page coming in and the one going out, so the
    // two stay edge to edge the whole way - and the same easing backwards,
    // flipped, so a pop is a push in reverse.
    Animation<double> eased(Animation<double> parent) => CurvedAnimation(
      parent: parent,
      curve: motion.move,
      reverseCurve: motion.move.flipped,
    );
    return SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(eased(animation)),
      child: SlideTransition(
        position: Tween(
          begin: Offset.zero,
          end: const Offset(-1, 0),
        ).animate(eased(secondaryAnimation)),
        child: child,
      ),
    );
  }
}
