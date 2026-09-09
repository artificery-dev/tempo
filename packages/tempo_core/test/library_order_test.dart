import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_core/src/settings/library_folders_screen.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

void main() {
  test('folder settings list libraries alphabetically', () {
    expect(LibraryFoldersScreen.sections.map((section) => section.label), [
      'Audiobooks',
      'Movies',
      'Music',
      'Podcasts',
      'Recordings',
      'Shows',
    ]);
  });

  for (final view in MenuLayout.values) {
    testWidgets('hold, move, place and restore libraries in ${view.name}', (
      tester,
    ) async {
      final settings = Settings(tree: playerSettingsTree);
      final wheel = ClickWheelController();
      Widget app(Settings store) => SettingsScope(
        settings: store,
        child: TomeApp(
          builder: (context, child) =>
              ClickWheelInput(controller: wheel, child: child!),
          home: LibraryMenuScreen(
            entry: systemMenu.at('/library')!,
            view: view,
          ),
        ),
      );
      await tester.pumpWidget(app(settings));
      await tester.pumpAndSettle();
      wheel.buttonDown(WheelButton.select);
      await tester.pump(const Duration(milliseconds: 700));
      wheel.buttonUp(WheelButton.select);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).title,
        'Moving Music',
      );
      wheel.jog(2);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).title,
        'Moving Music',
      );
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).title,
        'Library',
      );
      expect(settings.value(LibraryMenuScreen.orderPath), [
        'podcasts',
        'recordings',
        'music',
        'audiobooks',
        'movies',
        'shows',
      ]);
      final restored = Settings(
        tree: playerSettingsTree,
        values: settings.stored,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app(restored));
      await tester.pumpAndSettle();
      wheel.hold(WheelButton.select);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).title,
        'Moving Podcasts',
      );
      wheel.jog(-1);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).title,
        'Moving Podcasts',
      );
      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).title,
        'Library',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      restored.dispose();
    });
  }
}
