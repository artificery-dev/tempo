import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// The title, live status readings, and home clock.
void main() {
  tearDown(() {
    StatusReadings.batteryIcon.value = true;
    StatusReadings.batteryPercent.value = false;
    StatusReadings.wifiIcon.value = true;
    StatusReadings.bluetoothIcon.value = true;
    StatusReadings.playGlyph.value = true;
    StatusReadings.hideIdle.value = true;
    Playback.state.value = PlaybackState.stopped;
    ClockFormat.hour24.value = true;
    MenuDock.current.value = const [];
    MenuDock.selected.value = null;
  });

  /// The radios saying something, for the tests that want the trailing
  /// readings on the bar rather than an empty end.
  PlayerServices talkingRadios() => PlayerServices(
    battery: ValueNotifier(const BatteryReading(percent: 78)),
    wifi: ValueNotifier(
      const WifiReading(status: WifiStatus.connected, network: 'Net', bars: 3),
    ),
    bluetooth: ValueNotifier(
      const BluetoothReading(status: BluetoothStatus.connected, device: 'Buds'),
    ),
    storage: ValueNotifier(StorageReading.empty),
    places: PlayerServices.fallback.places,
    screen: ScreenSwitch(),
    volume: VolumeSwitch(),
    output: OutputSwitch(),
    feedback: FeedbackSwitch(),
  );

  Future<void> pumpBar(
    WidgetTester tester, {
    String title = 'Page',
    PlayerServices? services,
    bool panel = false,
  }) async {
    // The bar's title is only ever tight on the panel: a test surface is
    // four times its width, and a title that fits there tells us nothing.
    if (panel) {
      tester.view.physicalSize = Panel.pixels;
      tester.view.devicePixelRatio = Panel.devicePixelRatio;
      addTearDown(tester.view.reset);
    }
    final entry = systemMenu.at('/apps')!;
    DockChrome.of(entry.path).value = BarChrome(title: title);
    MenuDock.current.value = [entry];
    const bar = Stack(children: [StatusBar()]);
    final under = services == null
        ? bar
        : PlayerServicesScope(services: services, child: bar);
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        // On the panel the bar is drawn at the chrome scale, whose type is
        // a third the size of Tome's desktop face. A test that keeps the
        // desktop's type on a panel-sized surface is measuring a bar that
        // does not exist.
        theme: panel ? chromeScale.theme(Brightness.dark) : const Theme(),
        home: panel ? UiScaleScope(scale: chromeScale, child: under) : under,
      ),
    );
    await tester.pump();
  }

  /// Whether a title was cut to fit, rather than merely set smaller.
  bool cut(WidgetTester tester, String title) =>
      tester.renderObject<RenderParagraph>(find.text(title)).didExceedMaxLines;

  BatteryGaugePainter gaugePainter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.descendant(
                  of: find.byType(BatteryGauge),
                  matching: find.byType(CustomPaint),
                ),
              )
              .painter
          as BatteryGaugePainter;

  testWidgets(
    'card activity is shown for busy and unknown, hidden only when idle',
    (tester) async {
      final services = talkingRadios();
      final storage = services.storage as ValueNotifier<StorageReading>;
      storage.value = const StorageReading(present: true, busy: true);
      await pumpBar(tester, services: services, panel: true);
      expect(find.byIcon(LucideIcons.hardDriveDownload), findsOneWidget);
      storage.value = const StorageReading(present: true, busy: null);
      await tester.pump();
      expect(find.byIcon(LucideIcons.hardDriveDownload), findsOneWidget);
      storage.value = const StorageReading(present: true, busy: false);
      await tester.pump();
      expect(find.byIcon(LucideIcons.hardDriveDownload), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('the bar has no clock; the battery is the gauge, a glyph '
      'tall, in the bar\'s text color, with the percent in its field', (
    tester,
  ) async {
    await pumpBar(tester);
    expect(find.byType(ClockText), findsNothing);
    final theme = ThemeProvider.of(tester.element(find.byType(BatteryGauge)));
    final painter = gaugePainter(tester);
    expect(painter.outline, theme.palette.text);
    // No supply to read on a desktop: no percent after the cell, and
    // nothing else either.
    expect(painter.percent, isNull);
    expect(painter.leading, 0);
    expect(painter.percentStyle.fontWeight, readingWeight);
    expect(painter.percentStyle.fontSize, lessThan(statusGlyphSize(theme)));
    expect(
      tester.getSize(find.byType(BatteryGauge)).height,
      statusGlyphSize(theme),
    );
  });

  testWidgets('the play state leads and the battery ends; the leading '
      'glyph is a step above the trailing readings', (tester) async {
    // Something playing, so there is a leading glyph to measure at all.
    Playback.state.value = PlaybackState.playing;
    await pumpBar(tester, services: talkingRadios());
    expect(find.byIcon(LucideIcons.play), findsOneWidget);
    final glyph = tester.getTopLeft(find.byType(PlayStateGlyph)).dx;
    final battery = tester.getTopLeft(find.byType(BatteryGauge)).dx;
    expect(glyph, lessThan(battery));

    final theme = ThemeProvider.of(tester.element(find.byType(BatteryGauge)));
    // Two sizes, not one: the play state is read at the page name's
    // weight, and the cluster of readings at the end sits a step under it.
    expect(statusGlyphSize(theme), lessThan(readingGlyphSize(theme)));
    Iterable<double?> sizesIn(Finder of) => tester
        .widgetList<Icon>(find.descendant(of: of, matching: find.byType(Icon)))
        .map((icon) => icon.size);
    expect(
      sizesIn(find.byType(PlayStateGlyph)),
      everyElement(readingGlyphSize(theme)),
    );
    expect(
      sizesIn(find.byType(WifiStatusIcon)),
      everyElement(statusGlyphSize(theme)),
    );
    expect(
      tester.getSize(find.byType(BatteryGauge)).height,
      statusGlyphSize(theme),
    );

    Playback.state.value = PlaybackState.paused;
    await tester.pump();
    expect(find.byIcon(LucideIcons.pause), findsOneWidget);
    expect(find.byIcon(LucideIcons.play), findsNothing);
  });

  testWidgets('a stopped player shows no play state at all', (tester) async {
    await pumpBar(tester);
    // Stopped playback occupies no slot or spacing.
    expect(find.byType(PlayStateGlyph), findsNothing);
    expect(find.byIcon(LucideIcons.square), findsNothing);
    expect(find.byType(PlayStateGlyph), findsNothing);

    // Two states have a glyph, and stopped is not one of them.
    Playback.state.value = PlaybackState.playing;
    await tester.pump();
    expect(find.byIcon(LucideIcons.play), findsOneWidget);

    Playback.state.value = PlaybackState.stopped;
    await tester.pump();
    expect(find.byType(PlayStateGlyph), findsNothing);
  });

  testWidgets('the clock is on home: large in the middle while nothing '
      'plays, and gone - up into the bar - while something does', (
    tester,
  ) async {
    await tester.pumpWidget(
      const TomeApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox.expand(child: HomeClock()),
      ),
    );
    await tester.pump();
    final page = tester.getRect(find.byType(HomeClock));
    final theme = ThemeProvider.of(tester.element(find.byType(ClockText)));
    Text face() => tester.widget<Text>(
      find.descendant(of: find.byType(ClockText), matching: find.byType(Text)),
    );
    expect(face().data, matches(RegExp(r'^\d\d:\d\d$')));
    expect(face().style!.fontSize, HomeClock.restSize(theme));
    expect(face().style!.color, const Color(0xFFFFFFFF));
    var clock = tester.getRect(find.byType(ClockText));
    expect(clock.center.dx, closeTo(page.center.dx, 0.5));
    expect(clock.center.dy, closeTo(page.center.dy, 0.5));

    Playback.state.value = PlaybackState.playing;
    await tester.pumpAndSettle();
    expect(find.byType(ClockText), findsNothing);

    Playback.state.value = PlaybackState.stopped;
    await tester.pumpAndSettle();
    expect(face().style!.fontSize, HomeClock.restSize(theme));
  });

  testWidgets('the title stays left aligned before the status cluster', (
    tester,
  ) async {
    await pumpBar(tester);
    final bar = tester.getRect(find.byType(StatusBar));
    final title = tester.getRect(find.text('Page'));
    final theme = ThemeProvider.of(tester.element(find.text('Page')));
    expect(title.left, closeTo(bar.left + theme.space.x2, 0.5));
  });

  testWidgets('status settings update the cluster through their bindings', (
    tester,
  ) async {
    final services = talkingRadios();
    final settings = Settings(tree: playerSettingsTree);
    SettingBindings.registerAll(PlayerSettings.sinks(services));
    final bridge = SettingsBridge(settings: settings)..attach();
    addTearDown(() {
      bridge.detach();
      settings.dispose();
      SettingBindings.clear();
    });
    Playback.state.value = PlaybackState.playing;
    await pumpBar(tester, services: services);
    final title = tester.getRect(find.text('Page'));
    final play = tester.getRect(find.byType(PlayStateGlyph));
    final radios = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((widget) => widget.painter is BluetoothStatusPainter);
    expect(radios.length, 1);
    expect(find.byType(WifiStatusIcon), findsOneWidget);
    expect(title.right, lessThan(play.left));
    for (final id in [
      'play-glyph',
      'wifi-icon',
      'bluetooth-icon',
      'battery-icon',
    ]) {
      settings.set('/settings/appearance/status-bar/$id', false);
    }
    await tester.pump();
    expect(find.byType(PlayStateGlyph), findsNothing);
    expect(find.byType(BatteryGauge), findsNothing);
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((w) => w.painter is BluetoothStatusPainter),
      isEmpty,
    );
    expect(find.byType(WifiStatusIcon), findsNothing);
    settings.set('/settings/appearance/status-bar/battery-percent', true);
    await tester.pump();
    expect(find.text('78%'), findsOneWidget);
  });

  testWidgets('off radios are visible when hiding inactive icons is disabled', (
    tester,
  ) async {
    StatusReadings.hideIdle.value = false;
    await pumpBar(tester);
    final painters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter);
    expect(
      tester.widget<WifiStatusIcon>(find.byType(WifiStatusIcon)).status,
      WifiStatus.off,
    );
    expect(
      painters.whereType<BluetoothStatusPainter>().single.status,
      BluetoothStatus.off,
    );
    StatusReadings.hideIdle.value = true;
    await tester.pump();
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((w) => w.painter is BluetoothStatusPainter),
      isEmpty,
    );
  });

  testWidgets('Wi-Fi uses Lucide signal levels and the off icon', (
    tester,
  ) async {
    for (final entry in {
      0: LucideIcons.wifiZero,
      1: LucideIcons.wifiLow,
      2: LucideIcons.wifiHigh,
      3: LucideIcons.wifi,
    }.entries) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: WifiStatusIcon(
            status: WifiStatus.connected,
            bars: entry.key,
            color: const Color(0xffffffff),
            size: 24,
          ),
        ),
      );
      expect(find.byIcon(entry.value), findsOneWidget);
    }
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: WifiStatusIcon(
          status: WifiStatus.off,
          bars: 3,
          color: Color(0xffffffff),
          size: 24,
        ),
      ),
    );
    expect(find.byIcon(LucideIcons.wifiOff), findsOneWidget);
  });

  group('the clock format', () {
    test('a 24-hour dial pads the hour and has no meridiem', () {
      ClockFormat.hour24.value = true;
      expect(ClockFormat.parts(DateTime(2026, 9, 4, 9, 5)), ('09:05', null));
      expect(ClockFormat.parts(DateTime(2026, 9, 4, 21, 5)), ('21:05', null));
      expect(ClockFormat.parts(DateTime(2026, 9, 4, 0, 0)), ('00:00', null));
      expect(ClockFormat.format(DateTime(2026, 9, 4, 21, 5)), '21:05');
    });

    test('a 12-hour dial drops the leading zero and says which half', () {
      ClockFormat.hour24.value = false;
      expect(ClockFormat.parts(DateTime(2026, 9, 4, 9, 5)), ('9:05', 'AM'));
      expect(ClockFormat.parts(DateTime(2026, 9, 4, 21, 5)), ('9:05', 'PM'));
      expect(ClockFormat.format(DateTime(2026, 9, 4, 21, 5)), '9:05 PM');
    });

    test('midnight and noon are twelve, not zero', () {
      ClockFormat.hour24.value = false;
      expect(ClockFormat.parts(DateTime(2026, 9, 4, 0, 30)), ('12:30', 'AM'));
      expect(ClockFormat.parts(DateTime(2026, 9, 4, 12, 30)), ('12:30', 'PM'));
    });

    testWidgets('the meridiem is set well under the digits, on their own '
        'baseline', (tester) async {
      ClockFormat.hour24.value = false;
      await tester.pumpWidget(
        const TomeApp(
          debugShowCheckedModeBanner: false,
          home: Center(child: ClockText()),
        ),
      );
      await tester.pump();

      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      final digits = texts.firstWhere((t) => t.data!.contains(':'));
      final meridiem = texts.firstWhere(
        (t) => t.data == 'PM' || t.data == 'AM',
      );
      // The hour is the reading; the meridiem only says which half it is.
      expect(
        meridiem.style!.fontSize!,
        lessThan(digits.style!.fontSize! * 0.6),
      );

      // Whatever the format, the clock is one line that fits its panel.
      final row = tester.getSize(find.byType(ClockText));
      expect(row.width, lessThan(800));
    });

    testWidgets('every clock on the player follows the one setting', (
      tester,
    ) async {
      ClockFormat.hour24.value = true;
      await tester.pumpWidget(
        const TomeApp(
          debugShowCheckedModeBanner: false,
          home: Center(child: ClockText()),
        ),
      );
      await tester.pump();
      expect(find.textContaining('AM'), findsNothing);
      expect(find.textContaining('PM'), findsNothing);

      ClockFormat.hour24.value = false;
      await tester.pump();
      expect(find.textContaining(RegExp('AM|PM')), findsOneWidget);
    });
  });

  group('the bar\'s title', () {
    testWidgets('an ordinary screen name fits whole, radios and all', (
      tester,
    ) async {
      // With the battery's percent off - which is what the tree has always
      // said it is - the trailing end is two glyphs and a gauge, and a
      // name like this has the room it needs.
      await pumpBar(
        tester,
        title: 'Appearance',
        services: talkingRadios(),
        panel: true,
      );
      expect(find.text('Appearance'), findsOneWidget);
      expect(
        cut(tester, 'Appearance'),
        isFalse,
        reason: 'a plain screen name should not come out "Appear..."',
      );
    });

    testWidgets('and so does the longest of the player\'s own', (tester) async {
      for (final title in const [
        'Appearance',
        'Status Bar',
        'Home & Menus',
        'Time & Language',
      ]) {
        await pumpBar(
          tester,
          title: title,
          services: talkingRadios(),
          panel: true,
        );
        expect(cut(tester, title), isFalse, reason: '"$title" was cut');
      }
    });

    testWidgets('a name too long for any size is cut rather than vanishing', (
      tester,
    ) async {
      const album = 'Hazbin Hotel: Season Two (Original Soundtrack)';
      await pumpBar(
        tester,
        title: album,
        services: talkingRadios(),
        panel: true,
      );
      expect(cut(tester, album), isTrue);
      // Cut, but still readable: it never shrinks past the floor.
      final theme = ThemeProvider.of(tester.element(find.text(album)));
      final painted = tester
          .renderObject<RenderParagraph>(find.text(album))
          .text
          .style!
          .fontSize!;
      expect(painted, greaterThanOrEqualTo(barTypeSize(theme) * 0.6));
    });
  });

  group('the battery percent', () {
    tearDown(() => StatusReadings.batteryPercent.value = false);

    testWidgets('is off by default, as the tree says', (tester) async {
      expect(StatusReadings.batteryPercent.value, isFalse);
      expect(
        playerSettingsTree
            .at('/settings/appearance/status-bar/battery-percent')!
            .node
            .defaultValue,
        false,
      );
      await pumpBar(tester, services: talkingRadios());
      // The gauge paints its number rather than laying out a Text, so the
      // painter is what knows whether there is one.
      expect(gaugePainter(tester).percent, isNull);
    });

    testWidgets('and written beside the gauge when it is turned on', (
      tester,
    ) async {
      StatusReadings.batteryPercent.value = true;
      await pumpBar(tester, services: talkingRadios());
      expect(gaugePainter(tester).percent, '78');
    });

    testWidgets('still leaves room for a left-aligned screen title', (
      tester,
    ) async {
      const title = 'Time & Language';
      await pumpBar(
        tester,
        title: title,
        services: talkingRadios(),
        panel: true,
      );
      expect(cut(tester, title), isFalse);

      StatusReadings.batteryPercent.value = true;
      await tester.pumpAndSettle();
      expect(
        cut(tester, title),
        isFalse,
        reason: 'left alignment leaves enough room for the title',
      );
    });
  });
}
