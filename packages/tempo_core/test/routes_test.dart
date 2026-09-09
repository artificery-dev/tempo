import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Inside an app, pages slide: the new one in from the right as the old
/// one leaves to the left, edge to edge, and back the other way - never
/// one translucent page over another.
void main() {
  tearDown(MenuDock.reset);

  /// The Library app, which is a menu of menus - the shape this is about.
  Future<ClickWheelController> pumpLibrary(WidgetTester tester) async {
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel));
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    wheel.jog(2 * MenuDock.physics.weight);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.byType(LibraryMenuScreen), findsOneWidget);
    return wheel;
  }

  Finder pageAt(String path) => find.byWidgetPredicate(
    (widget) => switch (widget) {
      MenuListScreen(:final entry) => entry.path == path,
      LibraryMenuScreen(:final entry) => entry.path == path,
      _ => false,
    },
  );

  Rect rectOf(WidgetTester tester, String path) => tester.getRect(pageAt(path));

  testWidgets('a push slides the new page in from the right as the old '
      'leaves to the left, edge to edge; a pop slides back', (tester) async {
    final wheel = await pumpLibrary(tester);
    final panel = tester.getRect(find.byType(LibraryMenuScreen));
    final pushed = systemMenu.at('/library')!.children.first.path;

    wheel.press(WheelButton.select);
    await tester.pump();
    await tester.pump(PanelRoute.motion.standard ~/ 2);
    final old = rectOf(tester, '/library');
    final fresh = rectOf(tester, pushed);
    expect(old.left, lessThan(panel.left), reason: 'leaving to the left');
    expect(
      fresh.left,
      greaterThan(panel.left),
      reason: 'coming from the right',
    );
    expect(fresh.left, lessThan(panel.right));
    expect(fresh.left, closeTo(old.right, 1e-6), reason: 'edge to edge');
    expect(old.width, panel.width);
    expect(fresh.width, panel.width);

    await tester.pumpAndSettle();
    expect(rectOf(tester, pushed), panel);
    expect(pageAt('/library'), findsNothing, reason: 'old offstage');

    wheel.press(WheelButton.menu);
    await tester.pump();
    await tester.pump(PanelRoute.motion.standard ~/ 2);
    final back = rectOf(tester, '/library');
    final going = rectOf(tester, pushed);
    expect(back.left, lessThan(panel.left));
    expect(going.left, greaterThan(panel.left));
    expect(going.left, closeTo(back.right, 1e-6), reason: 'edge to edge');

    await tester.pumpAndSettle();
    expect(rectOf(tester, '/library'), panel);
    expect(find.byType(LibraryMenuScreen), findsOneWidget);
  });
}
