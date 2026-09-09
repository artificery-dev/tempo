import 'package:tomeui/tomeui.dart';

import 'dock.dart';
import 'scale.dart';
import 'wallpaper.dart';

/// A screen with the status bar over it: the page, its name on the bar,
/// and [child] filling the rest, starting under the bar.
///
/// The bar itself is the app's one [StatusBar]; a page only tells it what
/// to say ([PublishChrome]) and keeps its content clear of it. Every
/// screen that is a list is one of these, so the rows start where the
/// rows on the last screen did.
///
/// The page itself is the wallpaper. A page is not a surface: the
/// surfaces are the rows and cards standing on it, and the picture is
/// seen around the solid ones and through the translucent ones. Only a
/// screen that is genuinely one surface filling the panel asks for
/// [Backdrop.opaque].
class PanelScreen extends StatelessWidget {
  const PanelScreen({
    required this.title,
    required this.child,
    this.backdrop = Backdrop.clear,
    super.key,
  });

  final String title;
  final Widget child;

  /// What lies between the page and the wallpaper.
  final Backdrop backdrop;

  @override
  Widget build(BuildContext context) {
    return PublishChrome(
      chrome: BarChrome(title: title, backdrop: backdrop),
      child: Backdropped(
        backdrop: backdrop,
        child: Padding(
          padding: EdgeInsets.only(top: chromeScale.barHeight),
          child: child,
        ),
      ),
    );
  }
}
