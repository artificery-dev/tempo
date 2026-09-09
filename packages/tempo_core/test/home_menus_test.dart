import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

const _track = TrackSummary(
  id: 1,
  fileId: 1,
  path: '/m/a',
  title: 'Devils Haircut',
  artist: 'Beck',
  album: 'Odelay',
  duration: Duration(minutes: 3, seconds: 14),
);

/// Home & Menus: the settings that say what home shows, how the switcher
/// moves, and how a menu is drawn.
///
/// Every one of these is a row in a tree that was written long before
/// anything read it. What is checked here is the reading: that the row
/// moves the thing it names, and that turning it off takes that thing off
/// the screen rather than leaving it there greyed.
void main() {
  late SilentPlayback playback;
  late VolumeSwitch volume;

  /// The app on stage, for walking the dock by where it is rather than by
  /// how many detents away it happens to be.
  MenuLocation onStage() =>
      MenuDock.selected.value ?? MenuDock.current.value.first;

  setUp(() {
    MenuDock.reset();
    Playback.state.value = PlaybackState.stopped;
  });

  tearDown(() {
    Osd.hide();
    MenuDock.reset();
    MenuDock.selected.value = null;
    HomeOptions.clock.value = true;
    HomeOptions.barClock.value = true;
    HomeOptions.artwork.value = HomeArtwork.fit;
    DockOptions.flow.value = true;
    DockOptions.atRoot.value = true;
    MenuOptions.view.value = MenuLayout.list;
    MenuOptions.remember.value = true;
    MenuOptions.wrap.value = false;
  });

  Future<ClickWheelController> pumpApp(WidgetTester tester) async {
    final wheel = ClickWheelController();
    playback = SilentPlayback();
    volume = VolumeSwitch();
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: PlayerServices.fallback.places,
      screen: ScreenSwitch(),
      volume: volume,
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
      library: PlayerServices.fallback.library,
      playback: playback,
    );
    await tester.pumpWidget(
      PanelSurface(
        child: TempoApp(wheel: wheel, services: services),
      ),
    );
    await tester.pumpAndSettle();
    return wheel;
  }

  Future<void> playSomething(WidgetTester tester) async {
    await playback.play(const [_track], index: 0);
    await tester.pumpAndSettle();
  }

  group('what home shows', () {
    testWidgets(
      'music defaults to volume and OK switches scrub mode without hiding controls',
      (tester) async {
        final wheel = await pumpApp(tester);
        await playSomething(tester);
        final level = volume.value.level;
        wheel.jog(1);
        await tester.pumpAndSettle();
        expect(playback.value.position, Duration.zero);
        expect(volume.value.level, level + VolumeService.step);
        expect(find.byKey(PlaybackProgress.thumbKey), findsNothing);
        final height = tester
            .getSize(find.byKey(NowPlayingCard.cardKey))
            .height;
        wheel.press(WheelButton.select);
        await tester.pumpAndSettle();
        expect(find.byKey(PlaybackProgress.thumbKey), findsOneWidget);
        expect(
          tester.getSize(find.byKey(NowPlayingCard.cardKey)).height,
          height,
        );
        expect(DockChrome.of('/home').value.visible, isTrue);
        expect(playback.value.playing, isTrue);
        wheel.jog(1);
        await tester.pumpAndSettle();
        expect(playback.value.position, const Duration(seconds: 5));
        expect(volume.value.level, level + VolumeService.step);
        wheel.press(WheelButton.select);
        await tester.pumpAndSettle();
        expect(find.byKey(PlaybackProgress.thumbKey), findsNothing);
        wheel.jog(-1);
        await tester.pumpAndSettle();
        expect(playback.value.position, const Duration(seconds: 5));
        expect(volume.value.level, level);
        wheel.press(WheelButton.menu);
        await tester.pumpAndSettle();
        expect(MenuDock.shown.value, isTrue);
        Osd.hide();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('everything, by default', (tester) async {
      await pumpApp(tester);
      expect(find.byType(HomeClock), findsOneWidget);
      expect(find.byType(LibraryFooter), findsOneWidget);
      expect(playerSettingsTree.at('/settings/appearance/home/card'), isNull);
      expect(playerSettingsTree.at('/settings/appearance/home/banner'), isNull);
      await playSomething(tester);
      expect(find.byKey(NowPlayingCard.cardKey), findsOneWidget);
      // The clock moves up into the bar's title slot while something
      // plays, so the big one goes and a ClockText is what is left.
      MenuDock.select(systemMenu.at('/home')!);
      await tester.pumpAndSettle();
      expect(MenuDock.position.value, isNull);
      expect(MenuDock.preview.value, isNull);
      expect(find.byType(ClockText), findsOneWidget);
    });

    testWidgets('the clock off takes the clock off', (tester) async {
      await pumpApp(tester);
      expect(find.byType(HomeClock), findsOneWidget);

      HomeOptions.clock.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(HomeClock), findsNothing);
    });

    testWidgets('the artwork off takes the cover off', (tester) async {
      await pumpApp(tester);
      await playSomething(tester);
      await tester.pump();
      expect(find.byType(NowPlayingArt), findsOneWidget);

      HomeOptions.artwork.value = HomeArtwork.off;
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingArt), findsNothing);
    });

    testWidgets('fill crops the cover, fit shows the whole of it', (
      tester,
    ) async {
      await pumpApp(tester);
      await playSomething(tester);
      await tester.pump();

      expect(
        tester.widget<NowPlayingArt>(find.byType(NowPlayingArt)).cover,
        isFalse,
        reason: 'fit is the default, and fit is not a crop',
      );

      HomeOptions.artwork.value = HomeArtwork.fill;
      await tester.pumpAndSettle();
      expect(
        tester.widget<NowPlayingArt>(find.byType(NowPlayingArt)).cover,
        isTrue,
      );
    });

    testWidgets('the bar clock off puts the page name back', (tester) async {
      await pumpApp(tester);
      await playSomething(tester);
      expect(find.byType(ClockText), findsWidgets);

      HomeOptions.barClock.value = false;
      await tester.pumpAndSettle();
      // Nothing in the bar is a clock any more: home's own title is what
      // the slot holds, and home draws none.
      expect(find.byType(ClockText), findsNothing);
    });
  });

  group('the switcher', () {
    testWidgets('back at an app\'s root brings the dock up', (tester) async {
      final wheel = await pumpApp(tester);
      // Home > dock > Library.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(2 * MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isFalse);

      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isTrue);
    });

    testWidgets('and does not, with that turned off', (tester) async {
      final wheel = await pumpApp(tester);
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(2 * MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();

      DockOptions.atRoot.value = false;
      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isFalse);
      // The app is still there: back did nothing, rather than something
      // else.
      expect(MenuDock.selected.value?.path, '/library');
    });

    test('the covers turn, or slide flat', () {
      const panel = Size(480, 360);
      final turned = CoverGeometry(index: 1, at: 0, t: 1, panel: panel);
      final flat = CoverGeometry(
        index: 1,
        at: 0,
        t: 1,
        panel: panel,
        turning: false,
      );

      // Turned: dimmer to the side, and a matrix with a rotation in it.
      expect(turned.opacity, lessThan(1));
      expect(turned.transform.entry(0, 0), isNot(closeTo(1, 0.001)));

      // Flat: a translation, and nothing else. A page beside a page.
      expect(flat.opacity, 1.0);
      expect(flat.transform, Matrix4.translationValues(flat.shift, 0, 0));
      // And a whole width along, so the two do not overlap.
      expect(flat.shift, panel.width);
    });
  });

  group('the menu', () {
    testWidgets('a branch with no view of its own takes the default one', (
      tester,
    ) async {
      final wheel = await pumpApp(tester);
      // Home > dock > Library, which states no layout.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(2 * MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(
        tester.widget<LibraryMenuScreen>(find.byType(LibraryMenuScreen)).view,
        MenuLayout.list,
      );
      expect(find.byType(MenuGridScreen), findsNothing);

      MenuOptions.view.value = MenuLayout.grid;
      await tester.pumpAndSettle();
      expect(
        tester.widget<LibraryMenuScreen>(find.byType(LibraryMenuScreen)).view,
        MenuLayout.grid,
      );
    });

    testWidgets('Apps follows the global view and updates while open', (
      tester,
    ) async {
      final wheel = await pumpApp(tester);
      MenuOptions.view.value = MenuLayout.list;
      // Home > dock > Apps.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.byType(MenuListScreen), findsOneWidget);
      expect(find.byType(MenuGridScreen), findsNothing);

      MenuOptions.view.value = MenuLayout.grid;
      await tester.pumpAndSettle();
      expect(find.byType(MenuGridScreen), findsOneWidget);
      expect(find.byType(MenuListScreen), findsNothing);

      MenuOptions.view.value = MenuLayout.list;
      await tester.pumpAndSettle();
      expect(find.byType(MenuListScreen), findsOneWidget);
      expect(find.byType(MenuGridScreen), findsNothing);
    });

    testWidgets('an app reopens where it was left, unless told not to', (
      tester,
    ) async {
      final wheel = await pumpApp(tester);

      /// The dock, along [along] entries from Home, and in.
      Future<void> toApp(int along) async {
        wheel.powerDown();
        wheel.powerUp();
        await tester.pump(const Duration(milliseconds: 100));
        wheel.powerDown();
        wheel.powerUp();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        wheel.jog(
          (along - MenuDock.current.value.indexOf(onStage())) *
              MenuDock.physics.weight,
        );
        await tester.pumpAndSettle();
        wheel.press(WheelButton.select);
        await tester.pumpAndSettle();
      }

      // Library, then one level in: Music. A push inside the app, not a
      // hop to another one - Files is on the dock, so opening it from
      // Apps is choosing the dock's copy rather than stacking a screen.
      await toApp(2);
      expect(find.text('Music'), findsOneWidget);
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.text('Songs'), findsOneWidget);

      // Away and back: still in Music.
      await toApp(0);
      await toApp(2);
      expect(find.text('Songs'), findsOneWidget);

      // Told not to remember, leaving is what puts it back.
      MenuOptions.remember.value = false;
      await toApp(0);
      await toApp(2);
      expect(find.text('Songs'), findsNothing);
      expect(find.text('Music'), findsOneWidget);
    });
  });

  group('the wallpaper fit', () {
    tearDown(() => WallpaperSource.fit.value = BoxFit.contain);

    test('reads the names the setting stores, and no others', () {
      expect(WallpaperSource.fitNamed('contain'), BoxFit.contain);
      expect(WallpaperSource.fitNamed('cover'), BoxFit.cover);
      expect(WallpaperSource.fitNamed('centre'), BoxFit.none);
      expect(WallpaperSource.fitNamed('center'), BoxFit.none);
      // A name from a newer build moves nothing rather than crashing.
      expect(WallpaperSource.fitNamed('parallax'), isNull);
      expect(WallpaperSource.fitNamed(null), isNull);
      expect(WallpaperSource.fitNamed(3), isNull);
    });
  });
}
