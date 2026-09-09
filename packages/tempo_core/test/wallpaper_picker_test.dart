import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The wallpaper picker: the cursor you can see, and the palettes that
/// arrive while you sit there.
void main() {
  late MemoryFileSystem machine;
  late Places places;
  late Settings settings;
  late ClickWheelController wheel;

  final entry = playerSettingsTree.at('/settings/appearance/wallpaper/image')!;

  setUp(() {
    machine = MemoryFileSystem();
    places = Places(fileSystem: machine, home: '/home/tempo');
    settings = Settings(tree: playerSettingsTree);
    wheel = ClickWheelController();
  });

  /// A small picture of one color, written to [path].
  void put(String path, {(int, int, int) color = (200, 60, 60)}) {
    final image = img.Image(width: 32, height: 24);
    final (r, g, b) = color;
    for (var y = 0; y < 24; y++) {
      for (var x = 0; x < 32; x++) {
        image.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    machine.file(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(image));
  }

  Future<void> pump(WidgetTester tester) async {
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: ValueNotifier(places),
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
      library: PlayerServices.fallback.library,
      playback: SilentPlayback(),
    );
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: PlayerServicesScope(
          services: services,
          child: SettingsScope(
            settings: settings,
            child: ClickWheelInput(
              controller: wheel,
              child: Navigator(
                onGenerateRoute: (_) => PanelRoute(
                  settings: const RouteSettings(name: '/settings'),
                  builder: (_) => WallpaperPickerScreen(entry: entry),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Not pumpAndSettle: the row under the wheel spins while its picture
    // is being read, and an indeterminate spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Let real work happen - the decode is in another isolate, and no
  /// amount of pumping fake time will finish it - then draw what came of
  /// it. Gives up after [within], so a failure is a failed expectation
  /// rather than a test that never returns.
  Future<void> settleReal(
    WidgetTester tester,
    bool Function() done, {
    Duration within = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(within);
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  bool hasDots(String path) =>
      find.byKey(WallpaperPickerScreen.dotsKey(path)).evaluate().isNotEmpty;

  group('the cursor', () {
    testWidgets('the row the wheel is on wears the list\'s card surface', (
      tester,
    ) async {
      put('/home/tempo/Wallpapers/one.png');
      put('/home/tempo/Wallpapers/two.png');
      put('/home/tempo/Wallpapers/three.png');
      await pump(tester);

      // Every row is dressed, and exactly one of them is the selected
      // one. Built rows are not dressed by the list, so a picker that
      // forgets this draws no cursor at all.
      final dressed = tester.widgetList<SettingCard>(find.byType(SettingCard));
      expect(dressed, isNotEmpty);
      expect(dressed.where((row) => row.selected), hasLength(1));
    });

    testWidgets('and it moves with the wheel', (tester) async {
      put('/home/tempo/Wallpapers/one.png');
      put('/home/tempo/Wallpapers/two.png');
      await pump(tester);

      SettingCard dressOn(String title) => tester.widget<SettingCard>(
        find.ancestor(of: find.text(title), matching: find.byType(SettingCard)),
      );

      expect(dressOn('one').selected, isTrue);
      expect(dressOn('two').selected, isFalse);

      wheel.jog(1);
      await tester.pump();
      expect(dressOn('one').selected, isFalse);
      expect(dressOn('two').selected, isTrue);
    });
  });

  group('the palettes', () {
    testWidgets('every picture in the folder colors itself in, not just '
        'the one under the wheel', (tester) async {
      put('/home/tempo/Wallpapers/a.png', color: (210, 50, 50));
      put('/home/tempo/Wallpapers/b.png', color: (50, 170, 90));
      put('/home/tempo/Wallpapers/c.png', color: (60, 90, 210));
      await pump(tester);

      const paths = [
        '/home/tempo/Wallpapers/a.png',
        '/home/tempo/Wallpapers/b.png',
        '/home/tempo/Wallpapers/c.png',
      ];
      await settleReal(tester, () => paths.every(hasDots));
      for (final path in paths) {
        expect(hasDots(path), isTrue, reason: '$path never arrived');
      }
    });

    testWidgets('the row the wheel is on is read first', (tester) async {
      for (final name in ['a', 'b', 'c', 'd', 'e']) {
        put('/home/tempo/Wallpapers/$name.png');
      }
      await pump(tester);

      // Down to the last row before anything has been read: what the
      // wheel settles on jumps the queue, whatever order the folder is
      // in.
      wheel.jog(4);
      await tester.pump();
      const last = '/home/tempo/Wallpapers/e.png';
      await settleReal(tester, () => hasDots(last));
      expect(hasDots(last), isTrue);
      expect(
        hasDots('/home/tempo/Wallpapers/b.png'),
        isFalse,
        reason: 'the sweep read outwards from the wheel, not from the top',
      );
    });

    testWidgets('bring a square of the picture with them', (tester) async {
      put('/home/tempo/Wallpapers/a.png');
      await pump(tester);

      // Nothing before the read: a box the picture's size, so the row
      // does not change shape when it arrives.
      expect(find.byType(Image), findsNothing);

      const path = '/home/tempo/Wallpapers/a.png';
      await settleReal(tester, () => hasDots(path));
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('a folder gets a glyph rather than a square', (tester) async {
      put('/home/tempo/Wallpapers/Nested/deep.png');
      await pump(tester);

      final row = tester.widget<SettingTile>(
        find.ancestor(
          of: find.text('Nested'),
          matching: find.byType(SettingTile),
        ),
      );
      expect(row.leading, isNull);
      expect(row.icon, isNotNull);
    });

    testWidgets('a file that is not a picture is asked once and let be', (
      tester,
    ) async {
      put('/home/tempo/Wallpapers/good.png');
      machine.file('/home/tempo/Wallpapers/broken.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3, 4]);
      await pump(tester);

      const broken = '/home/tempo/Wallpapers/broken.png';
      const good = '/home/tempo/Wallpapers/good.png';
      // Both are answered - the broken one with no colors at all - and
      // the sweep moves on rather than trying it again forever.
      await settleReal(tester, () => hasDots(broken) && hasDots(good));
      expect(hasDots(broken), isTrue);
      expect(hasDots(good), isTrue);
    });

    testWidgets('a folder row has no palette and does not stop the sweep', (
      tester,
    ) async {
      put('/home/tempo/Wallpapers/Nested/deep.png');
      put('/home/tempo/Wallpapers/flat.png');
      await pump(tester);

      // Folders sort first, so the wheel opens on one: the sweep has to
      // read outwards from a row that has nothing of its own.
      expect(find.text('Nested'), findsOneWidget);
      const flat = '/home/tempo/Wallpapers/flat.png';
      await settleReal(tester, () => hasDots(flat));
      expect(hasDots(flat), isTrue);
    });
  });
}
