import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Apps follows the global view. In grid mode the wheel walks across
/// each row before advancing to the next.
void main() {
  testWidgets('Apps opens its apps using the global grid view', (tester) async {
    final apps = systemMenu.at('/apps')!;
    expect(apps.node.layout, isNull);
    MenuOptions.view.value = MenuLayout.grid;
    addTearDown(() => MenuOptions.view.value = MenuLayout.list);

    final wheel = ClickWheelController();
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            ClickWheelInput(controller: wheel, child: child!),
        home: MenuScreens.branchPage(apps),
      ),
    );
    await tester.pumpAndSettle();

    // Files then Store, side by side on the first row (Files wears the
    // cursor's plate, which insets its words by a few pixels).
    final files = tester.getTopLeft(find.text('Files'));
    final store = tester.getTopLeft(find.text('Store'));
    expect(store.dx, greaterThan(files.dx));
    expect(store.dy, closeTo(files.dy, 6));

    // The wheel starts on Files; the center button opens it.
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.byType(FilesScreen), findsOneWidget);
  });

  test('the layout survives the JSON round trip', () {
    final json = systemMenu.root.toJson();
    final apps = (json['children'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((node) => node['id'] == 'apps');
    expect(apps['layout'], isNull);
    expect(MenuNode.fromJson(json), systemMenu.root);
  });
}
