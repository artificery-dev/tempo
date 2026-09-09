import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Choosing the three swatches the UI is mixed from: the picker, what it
/// writes, and what the theme comes out as afterwards.
void main() {
  late Settings settings;
  late SettingsBridge bridge;
  late ClickWheelController wheel;

  final primary = playerSettingsTree.at(
    '/settings/appearance/colours/primary',
  )!;
  const path = '/settings/appearance/colours/primary';

  setUp(() {
    settings = Settings(tree: playerSettingsTree);
    SettingBindings.registerAll({
      'appearance.primary': (change) =>
          Appearance.primary.value = '${change.to}',
      'appearance.accent': (change) => Appearance.accent.value = '${change.to}',
      'appearance.neutral': (change) =>
          Appearance.neutral.value = '${change.to}',
    });
    bridge = SettingsBridge(settings: settings)..attach();
    wheel = ClickWheelController();
  });

  tearDown(() {
    bridge.detach();
    Appearance.resetColors();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: SettingsScope(
          settings: settings,
          child: ClickWheelInput(
            controller: wheel,
            child: Navigator(
              onGenerateRoute: (_) => PanelRoute(
                settings: const RouteSettings(name: '/settings/appearance'),
                builder: (_) => SettingColorScreen(entry: primary),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the tree', () {
    test('a color is a control that exists now, not a promise', () {
      expect(primary.node.kind, SettingKind.setting);
      expect(primary.node.control, SettingControl.color);
      expect(primary.node.defaultValue, Appearance.defaultPrimary);
    });

    test('the default is one of the swatches on offer', () {
      for (final role in ['primary', 'accent', 'neutral']) {
        final entry = playerSettingsTree.at(
          '/settings/appearance/colours/$role',
        )!;
        expect(entry.node.defaultValue, Appearance.fromWallpaper);
        expect(
          SettingColorScreen.names,
          contains(entry.node.defaultValue),
          reason: '$role: the default is not on the ramp',
        );
      }
    });
  });

  group('the picker', () {
    testWidgets('shows every swatch, and rings the one in use', (tester) async {
      await pump(tester);
      expect(find.text('Sky'), findsOneWidget);
      expect(find.text('Zinc'), findsOneWidget);
      expect(find.text('Red'), findsOneWidget);
      // The wallpaper leads, and then every name Tome has.
      expect(SettingColorScreen.names.first, Appearance.fromWallpaper);
      expect(SettingColorScreen.names.skip(1), hasLength(Swatch.named.length));
      expect(find.text('Auto'), findsOneWidget);
    });

    testWidgets('choosing one writes its name and remixes the theme', (
      tester,
    ) async {
      await pump(tester);
      expect(Appearance.primary.value, Appearance.defaultPrimary);
      final before = Appearance.themeFor(Brightness.dark).palette.primary;

      // Red leads the ramp, so it is one press from the top of the grid.
      final red = SettingColorScreen.names.indexOf('red');
      final initial = SettingColorScreen.names.indexOf(
        Appearance.defaultPrimary,
      );
      for (var i = 0; i < red - initial; i++) {
        wheel.jog(1);
        await tester.pump();
      }
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();

      expect(settings.value(path), 'red');
      expect(Appearance.primary.value, 'red');
      final after = Appearance.themeFor(Brightness.dark).palette.primary;
      expect(after, isNot(before), reason: 'the theme should have remixed');
      expect(after, Swatch.red);
    });
  });

  group('the swatches behind the names', () {
    test('a name resolves to its ramp, and an unknown one to nothing', () {
      expect(Swatch.byName('sky'), Swatch.sky);
      expect(Swatch.byName('zinc'), Swatch.zinc);
      expect(Swatch.byName('chartreuse'), isNull);
      expect(Swatch.byName(null), isNull);
    });

    test('an unrecognised name leaves the theme on Tome\'s own default', () {
      Appearance.primary.value = 'chartreuse';
      // Not a crash, and not a color nobody asked for: the role's default.
      expect(Appearance.themeFor(Brightness.dark).palette.primary, Swatch.sky);
    });

    test('reset puts all three back', () {
      Appearance.primary.value = 'red';
      Appearance.accent.value = 'lime';
      Appearance.neutral.value = 'stone';
      Appearance.resetColors();
      expect(Appearance.primary.value, Appearance.defaultPrimary);
      expect(Appearance.accent.value, Appearance.defaultAccent);
      expect(Appearance.neutral.value, Appearance.defaultNeutral);
    });

    test('the reset action writes back through the store, not past it', () {
      final services = PlayerServices.fallback;
      SettingBindings.registerActions(
        PlayerSettings.actions(services, settings: settings),
      );
      settings.set(path, 'red');
      expect(Appearance.primary.value, 'red');

      SettingBindings.invoke(
        'appearance.resetColours',
        '/settings/appearance/colours/reset',
      );
      // The stored value moved too, or the next boot would put red back.
      expect(settings.value(path), Appearance.defaultPrimary);
      expect(Appearance.primary.value, Appearance.defaultPrimary);
    });
  });

  group('a slot that follows the wallpaper', () {
    tearDown(() => WallpaperSource.palettes.value = const []);

    test('takes the picture\'s swatch for its own role', () {
      WallpaperSource.palettes.value = const [
        WallpaperPalette(primary: 'teal', accent: 'rose', neutral: 'stone'),
      ];
      expect(
        Appearance.swatchFor(Appearance.fromWallpaper, 'primary'),
        Swatch.teal,
      );
      expect(
        Appearance.swatchFor(Appearance.fromWallpaper, 'accent'),
        Swatch.rose,
      );
      expect(
        Appearance.swatchFor(Appearance.fromWallpaper, 'neutral'),
        Swatch.stone,
      );
    });

    test('and nothing at all where there is no picture to ask', () {
      WallpaperSource.palettes.value = const [];
      expect(Appearance.swatchFor(Appearance.fromWallpaper, 'primary'), isNull);
    });

    test('a named slot ignores the wallpaper entirely', () {
      WallpaperSource.palettes.value = const [
        WallpaperPalette(primary: 'teal', accent: 'rose', neutral: 'stone'),
      ];
      expect(Appearance.swatchFor('lime', 'primary'), Swatch.lime);
    });

    testWidgets('the theme re-mixes when the wallpaper changes', (
      tester,
    ) async {
      Appearance.primary.value = Appearance.fromWallpaper;
      addTearDown(Appearance.resetColors);

      WallpaperSource.palettes.value = const [
        WallpaperPalette(primary: 'teal', accent: 'rose', neutral: 'stone'),
      ];
      expect(Appearance.theme.value.palette.primary, Swatch.teal);

      WallpaperSource.palettes.value = const [
        WallpaperPalette(primary: 'amber', accent: 'sky', neutral: 'ash'),
      ];
      expect(Appearance.theme.value.palette.primary, Swatch.amber);
    });
  });

  group('which of the wallpaper\'s palettes is taken', () {
    tearDown(() {
      WallpaperSource.palettes.value = const [];
      WallpaperSource.paletteIndex.value = 0;
    });

    const readings = [
      WallpaperPalette(primary: 'teal', accent: 'rose', neutral: 'stone'),
      WallpaperPalette(primary: 'amber', accent: 'sky', neutral: 'stone'),
    ];

    test('the best of them, by default', () {
      WallpaperSource.palettes.value = readings;
      expect(WallpaperSource.palette, readings.first);
    });

    test('and whichever was chosen, once one was', () {
      WallpaperSource.palettes.value = readings;
      WallpaperSource.paletteIndex.value = 1;
      expect(WallpaperSource.palette, readings[1]);
      expect(
        Appearance.swatchFor(Appearance.fromWallpaper, 'primary'),
        Swatch.amber,
      );
    });

    test('a choice past the end of a shorter picture falls back', () {
      WallpaperSource.paletteIndex.value = 2;
      WallpaperSource.palettes.value = const [
        WallpaperPalette(primary: 'lime', accent: 'sky', neutral: 'ash'),
      ];
      expect(WallpaperSource.palette!.primary, 'lime');
    });

    test('and a picture with no colors has none to take', () {
      WallpaperSource.palettes.value = const [];
      WallpaperSource.paletteIndex.value = 1;
      expect(WallpaperSource.palette, isNull);
    });

    testWidgets('the theme re-mixes when the choice moves', (tester) async {
      Appearance.primary.value = Appearance.fromWallpaper;
      addTearDown(Appearance.resetColors);
      WallpaperSource.palettes.value = readings;
      expect(Appearance.theme.value.palette.primary, Swatch.teal);
      WallpaperSource.paletteIndex.value = 1;
      expect(Appearance.theme.value.palette.primary, Swatch.amber);
    });
  });
}
