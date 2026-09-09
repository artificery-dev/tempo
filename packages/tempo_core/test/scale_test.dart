import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The UI is drawn at a [UiScale]: the classic one by default, laid out
/// for the panel's pixels, and the first UI kept whole as the large one.
/// What is checked is that the numbers add up to the panel, and that the
/// scale actually reaches the screens - the rows, the bar, the type - and
/// moves them when it changes.
void main() {
  tearDown(() {
    Appearance.scale.value = UiScale.regular;
    MenuDock.reset();
    MenuDock.selected.value = null;
  });

  /// From home: the dock up, along to [index], and in.
  Future<void> dockTo(
    WidgetTester tester,
    ClickWheelController wheel,
    int index,
  ) async {
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    if (index != 0) wheel.jog(index * MenuDock.physics.weight);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
  }

  test('classic is one rhythm in whole pixels: a 40-pixel bar and 53-pixel '
      'rows in every list', () {
    const classic = UiScale.regular;
    double px(double dp) => dp * Panel.devicePixelRatio;
    expect(px(classic.barHeight), closeTo(40, 1e-9));
    expect(px(classic.rowExtent), closeTo(53, 1e-9));
    expect(classic.fileRowExtent, classic.rowExtent);
    // Six rows under the bar, and two pixels to spare.
    expect(px(classic.barHeight + 6 * classic.rowExtent), closeTo(358, 1e-9));
  });

  test('large is four rows to a screen, in Tome\'s own type', () {
    const large = UiScale.large;
    double px(double dp) => dp * Panel.devicePixelRatio;
    // The panel under the bar, divided exactly four ways.
    expect(px(4 * large.rowExtent), closeTo(320, 1e-9));
    expect(px(chromeScale.barHeight + 4 * large.rowExtent), closeTo(360, 1e-9));
    expect(large.fileRowExtent, large.rowExtent);
    // Tome's type, but not Tome's spacing: at the full ladder a row on a
    // 175dp panel spends more of its width on air than on words.
    expect(large.typography, const Typography());
    expect(large.space, isNot(const Space()));
    expect(large.rowExtent, greaterThan(UiScale.regular.rowExtent));
  });

  test('compact is seven rows where regular is six', () {
    double px(double dp) => dp * Panel.devicePixelRatio;
    expect(px(UiScale.compact.rowExtent), closeTo(45, 1e-9));
    // Seven under the bar, and five pixels to spare.
    expect(
      px(chromeScale.barHeight + 7 * UiScale.compact.rowExtent),
      closeTo(355, 1e-9),
    );
    // The words come down with the rows.
    expect(
      UiScale.compact.typography.body.fontSize,
      lessThan(UiScale.regular.typography.body.fontSize!),
    );
  });

  test('the theme follows the scale', () {
    expect(
      Appearance.theme.value.typography,
      UiScale.regular.typography,
      reason: 'regular by default',
    );
    Appearance.scale.value = UiScale.large;
    expect(Appearance.theme.value.typography, const Typography());
    expect(
      Appearance.themeFor(Brightness.light).palette.brightness,
      Brightness.light,
    );
    expect(
      Appearance.themeFor(Brightness.dark, scale: UiScale.regular).typography,
      UiScale.regular.typography,
      reason: 'a scale asked for by name wins over the current one',
    );
  });

  testWidgets('the menu is drawn at the scale, and redrawn when it moves', (
    tester,
  ) async {
    MenuOptions.view.value = MenuLayout.grid;
    addTearDown(() => MenuOptions.view.value = MenuLayout.list);
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel));
    await tester.pumpAndSettle();
    await dockTo(tester, wheel, 1);

    // Apps is a grid of glyphs; its cells are the scale's, and the name
    // under each glyph is set in the scale's caption.
    WheelGrid grid() => tester.widget<WheelGrid>(find.byType(WheelGrid));
    double tileTextSize() =>
        tester.widget<Text>(find.text('Files')).style!.fontSize!;

    // The bar names the level, the cells are classic cells, the type is
    // classic type.
    expect(find.byType(StatusBar), findsOneWidget);
    expect(
      find.descendant(of: find.byType(StatusBar), matching: find.text('Apps')),
      findsOneWidget,
    );
    expect(grid().cellExtent, UiScale.regular.gridCellExtent);
    expect(grid().columns, UiScale.regular.gridColumns);
    expect(tileTextSize(), UiScale.regular.typography.caption.fontSize);

    Appearance.scale.value = UiScale.large;
    await tester.pumpAndSettle();
    expect(grid().cellExtent, UiScale.large.gridCellExtent);
    expect(tileTextSize(), UiScale.large.typography.caption.fontSize);
  });

  testWidgets('the bar names every screen', (tester) async {
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel));
    await tester.pumpAndSettle();

    Future<void> open(int index) async {
      if (index != 0) wheel.jog(index);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
    }

    Future<void> back() async {
      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
    }

    String barTitle() => tester
        .widget<LabelText>(
          find.descendant(
            of: find.byType(StatusBar),
            matching: find.byType(LabelText),
          ),
        )
        .data;

    // Home has no name on the bar: it is the wallpaper, with the readings
    // in its margin.
    expect(find.byType(StatusBar), findsOneWidget);
    expect(barTitle(), '');

    // Apps launches Store on its own stage, with its own bar title.
    await dockTo(tester, wheel, 1);
    expect(barTitle(), 'Apps');
    await open(2);
    expect(find.byType(PlaceholderScreen), findsOneWidget);
    expect(barTitle(), 'Store');

    // Back at the root of an app is the switcher, which opens on it; the
    // bar names what is under the box as it moves.
    await back();
    expect(MenuDock.shown.value, isTrue);
    expect(barTitle(), 'Store');
    wheel.jog(-MenuDock.physics.weight);
    await tester.pumpAndSettle();
    expect(barTitle(), 'Files');
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(barTitle(), 'Files');

    // And a settings page: Appearance, whose own rows are switches and
    // choices rather than menu entries.
    await back();
    wheel.jog(-MenuDock.physics.weight);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(barTitle(), 'Settings');
    await open(3);
    expect(barTitle(), 'Appearance');
    await back();
    expect(barTitle(), 'Settings');
  });

  testWidgets('outside a scope a screen is classic', (tester) async {
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: MenuListScreen(entry: systemMenu.at('/library')!),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<WheelList>(find.byType(WheelList)).itemExtent,
      UiScale.regular.rowExtent,
    );
  });
}
