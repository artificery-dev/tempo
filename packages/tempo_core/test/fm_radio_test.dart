import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_core/src/content_surface.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

void main() {
  late MemoryFileSystem machine;
  late AppletStore store;
  late Applet applet;
  late FmRadioSwitch radio;
  late FmRadioSession session;
  late SilentPlayback playback;
  late ClickWheelController wheel;

  setUp(() {
    machine = MemoryFileSystem();
    final places = Places(fileSystem: machine, home: '/home/tempo');
    store = AppletStore(places);
    applet = Applet(entry: systemMenu.at('/apps')!, store: store);
    radio = FmRadioSwitch();
    session = FmRadioSession(radio: radio, memory: applet.state);
    playback = SilentPlayback();
    wheel = ClickWheelController();
    FmRadioSession.activate(session);
  });

  tearDown(() async {
    await FmRadioSession.stopActive();
    await session.close();
    MenuDock.reset();
    applet.dispose();
    radio.dispose();
    playback.dispose();
  });

  Future<void> pumpRadio(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: ValueNotifier(Places(fileSystem: machine, home: '/home/tempo')),
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
      fmRadio: radio,
      applets: store,
      playback: playback,
    );
    await tester.pumpWidget(
      TomeApp(
        theme: UiScale.regular.theme(Brightness.dark),
        debugShowCheckedModeBanner: false,
        home: PlayerServicesScope(
          services: services,
          child: UiScaleScope(
            scale: UiScale.regular,
            child: AppletScope(
              applet: applet,
              child: ClickWheelInput(
                controller: wheel,
                child: FmRadioNowPlaying(session: session),
              ),
            ),
          ),
        ),
      ),
    );
    await session.start();
    await tester.pump();
  }

  testWidgets('the wheel tunes and center persists favorite stations', (
    tester,
  ) async {
    await pumpRadio(tester);
    expect(radio.value.on, isTrue);
    expect(find.text('95.5'), findsOneWidget);
    expect(find.byKey(const Key('FmRadio.analogueBand')), findsOneWidget);
    expect(find.byKey(const Key('FmRadio.tunedStationLine')), findsOneWidget);

    wheel.jog(1);
    await tester.pump();
    expect(find.text('95.6'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    expect(radio.value.frequencyKhz, 95600);

    wheel.press(WheelButton.select);
    await tester.pump();
    expect(find.byIcon(LucideIcons.star), findsOneWidget);
    applet.state.flush();
    expect(
      Applet(
        entry: systemMenu.at('/apps')!,
        store: store,
      ).state.get<List<Object?>>('favorites'),
      [95600],
    );
  });

  testWidgets('receiver stereo and complete RDS fields reach Now Playing', (
    tester,
  ) async {
    await pumpRadio(tester);
    radio.value = radio.value.copyWith(stereo: false);
    await tester.pump();
    expect(find.textContaining('Mono'), findsOneWidget);
    radio.value = radio.value.copyWith(stereo: true);
    await tester.pump();
    expect(find.textContaining('Stereo'), findsOneWidget);
    radio.value = radio.value.copyWith(
      programName: 'Test FM',
      radioText: 'Artist — Track',
    );
    await tester.pump();
    expect(find.text('Test FM'), findsOneWidget);
    expect(find.text('Artist — Track'), findsOneWidget);
    expect(find.byType(GridCard), findsNothing);
    expect(find.textContaining('Headphones are the antenna'), findsNothing);
    final favorite = tester.getRect(find.byKey(const Key('FmRadio.favorite')));
    final rds = tester.getRect(find.byKey(const Key('FmRadio.rds')));
    final status = tester.getRect(find.byKey(const Key('FmRadio.status')));
    final dial = tester.getRect(find.byKey(const Key('FmRadio.dial')));
    expect(favorite.right, lessThan(rds.left));
    expect(rds.right, lessThan(status.left));
    expect(rds.bottom, lessThan(dial.top));
    expect(find.text('Stereo'), findsOneWidget);
    radio.value = radio.value.copyWith(clearStation: true);
    await tester.pump();
    expect(find.text('Test FM'), findsNothing);
    expect(find.text('Artist — Track'), findsNothing);
  });

  testWidgets('receiver errors use the full tuner width without ellipsis', (
    tester,
  ) async {
    await pumpRadio(tester);
    const message =
        'RTL-SDR not found. Reconnect it, then press Play/Pause to retry.';
    radio.value = radio.value.copyWith(on: false, error: message);
    await tester.pump();
    expect(find.text('ERROR'), findsOneWidget);
    expect(find.text(message), findsOneWidget);
    final error = tester.getRect(find.byKey(const Key('FmRadio.error')));
    final status = tester.getRect(find.byKey(const Key('FmRadio.status')));
    expect(error.width, greaterThan(status.width * 4));
    final text = tester.widget<BodyText>(
      find.byKey(const Key('FmRadio.error')),
    );
    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
  });

  testWidgets('media controls pause and jump between favorites', (
    tester,
  ) async {
    applet.state
      ..set('frequency_khz', 100100)
      ..set('favorites', [95500, 100100])
      ..flush();
    await FmRadioSession.stopActive();
    session = FmRadioSession(radio: radio, memory: applet.state);
    FmRadioSession.activate(session);
    await pumpRadio(tester);
    expect(find.text('100.1'), findsOneWidget);

    wheel.press(WheelButton.previous);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('95.5'), findsOneWidget);
    expect(radio.value.frequencyKhz, 95500);

    wheel.press(WheelButton.playPause);
    await tester.pump();
    expect(radio.value.on, isFalse);
    expect(find.text('PAUSED'), findsOneWidget);

    applet.state.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      radio.value.on,
      isFalse,
      reason: 'the pause state survives navigation to another app',
    );
  });

  testWidgets('holding previous and next seeks instead of jumping favorites', (
    tester,
  ) async {
    await pumpRadio(tester);
    expect(find.text('95.5'), findsOneWidget);

    wheel.hold(WheelButton.next);
    await tester.pumpAndSettle();
    expect(find.text('100.1'), findsOneWidget);
    expect(radio.value.frequencyKhz, 100100);

    wheel.hold(WheelButton.previous);
    await tester.pumpAndSettle();
    expect(find.text('95.5'), findsOneWidget);
    expect(radio.value.frequencyKhz, 95500);
    applet.state.flush();
  });

  testWidgets('an active FM session is Home now playing', (tester) async {
    await pumpRadio(tester);
    await tester.pumpWidget(
      TomeApp(
        theme: UiScale.regular.theme(Brightness.dark),
        home: PlayerServicesScope(
          services: PlayerServices(
            battery: ValueNotifier(const BatteryReading(percent: 50)),
            wifi: ValueNotifier(WifiReading.off),
            bluetooth: ValueNotifier(BluetoothReading.off),
            storage: ValueNotifier(StorageReading.empty),
            places: ValueNotifier(
              Places(fileSystem: machine, home: '/home/tempo'),
            ),
            screen: ScreenSwitch(),
            volume: VolumeSwitch(),
            output: OutputSwitch(),
            feedback: FeedbackSwitch(),
            fmRadio: radio,
            applets: store,
            playback: playback,
          ),
          child: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FmRadioNowPlaying), findsOneWidget);
    expect(find.text('95.5'), findsOneWidget);
  });

  Future<void> pumpApps(WidgetTester tester) async {
    await FmRadioSession.stopActive();
    MenuDock.reset();
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: ValueNotifier(Places(fileSystem: machine, home: '/home/tempo')),
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
      fmRadio: radio,
      applets: store,
      playback: playback,
    );
    await tester.pumpWidget(
      PanelSurface(
        child: TempoApp(wheel: wheel, services: services),
      ),
    );
    await tester.pumpAndSettle();
    MenuDock.select(systemMenu.at('/apps')!);
    await tester.pumpAndSettle();
  }

  Finder appsPage() => find.byWidgetPredicate(
    (widget) =>
        (widget is MenuGridScreen && widget.entry.path == '/apps') ||
        (widget is MenuListScreen && widget.entry.path == '/apps'),
  );

  testWidgets(
    'FM opens only on Home and returning to Apps never relaunches it',
    (tester) async {
      await pumpApps(tester);
      final context = tester.element(appsPage());
      final apps = Applet.maybeOf(context)!;
      openMenuEntry(context, systemMenu.at('/apps/fm-radio')!);
      await tester.pumpAndSettle();
      final active = FmRadioSession.active;
      expect(active, isNotNull);
      expect(MenuDock.selected.value?.path, '/home');
      expect(radio.value.on, isTrue);
      expect(apps.navigator.currentState!.canPop(), isFalse);
      expect(DockChrome.of('/apps').value.title, 'Apps');

      MenuDock.select(systemMenu.at('/apps')!);
      await tester.pumpAndSettle();
      expect(MenuDock.selected.value?.path, '/apps');
      expect(appsPage(), findsOneWidget);
      openMenuEntry(
        tester.element(appsPage()),
        systemMenu.at('/apps/fm-radio')!,
      );
      await tester.pumpAndSettle();
      expect(FmRadioSession.active, same(active));
      expect(MenuDock.selected.value?.path, '/home');

      await FmRadioSession.stopActive();
      MenuDock.select(systemMenu.at('/apps')!);
      await tester.pumpAndSettle();
      expect(MenuDock.selected.value?.path, '/apps');
      expect(FmRadioSession.active, isNull);
      expect(radio.value.on, isFalse);
      expect(apps.navigator.currentState!.canPop(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a pinned FM shortcut launches Home and leaves Apps intact', (
    tester,
  ) async {
    final pins = MenuDock.pins.value;
    addTearDown(() => MenuDock.pins.value = pins);
    await pumpApps(tester);
    MenuDock.pins.value = [...pins, '/apps/fm-radio'];
    await tester.pumpAndSettle();
    MenuDock.shown.value = true;
    await tester.pumpAndSettle();
    final entries = MenuDock.current.value;
    wheel.jog(
      entries.indexOf(systemMenu.at('/apps/fm-radio')!) -
          entries.indexOf(systemMenu.at('/apps')!),
    );
    await tester.pumpAndSettle();
    expect(MenuDock.preview.value?.path, '/apps/fm-radio');
    expect(find.text('FM Radio'), findsWidgets);
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(MenuDock.selected.value?.path, '/home');
    expect(MenuDock.shown.value, isFalse);
    expect(radio.value.on, isTrue);
    MenuDock.select(systemMenu.at('/apps')!);
    await tester.pumpAndSettle();
    expect(appsPage(), findsOneWidget);
    expect(
      Applet.maybeOf(
        tester.element(appsPage()),
      )!.navigator.currentState!.canPop(),
      isFalse,
    );
    MenuDock.shown.value = true;
    await tester.pumpAndSettle();
    wheel.jog(
      entries.indexOf(systemMenu.at('/apps/fm-radio')!) -
          entries.indexOf(systemMenu.at('/apps')!),
    );
    await tester.pumpAndSettle();
    wheel.hold(WheelButton.menu);
    await tester.pumpAndSettle();
    wheel.jog(3); // Close app.
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(radio.value.on, isFalse);
    expect(FmRadioSession.active, isNull);
    expect(MenuDock.pins.value, contains('/apps/fm-radio'));
  });

  testWidgets('an unpinned app opens separately and preserves the Apps grid', (
    tester,
  ) async {
    final pins = MenuDock.pins.value;
    MenuDock.pins.value = const [];
    addTearDown(() => MenuDock.pins.value = pins);
    await pumpApps(tester);
    final apps = Applet.maybeOf(tester.element(appsPage()))!;
    openMenuEntry(tester.element(appsPage()), systemMenu.at('/apps/files')!);
    await tester.pumpAndSettle();
    expect(MenuDock.selected.value?.path, '/apps/files');
    expect(
      MenuDock.current.value.where((entry) => entry.path == '/apps/files'),
      hasLength(1),
    );
    expect(apps.navigator.currentState!.canPop(), isFalse);
    MenuDock.select(systemMenu.at('/apps')!);
    await tester.pumpAndSettle();
    expect(appsPage(), findsOneWidget);
    openMenuEntry(tester.element(appsPage()), systemMenu.at('/apps/files')!);
    await tester.pumpAndSettle();
    expect(
      MenuDock.current.value.where((entry) => entry.path == '/apps/files'),
      hasLength(1),
    );
    expect(apps.navigator.currentState!.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
