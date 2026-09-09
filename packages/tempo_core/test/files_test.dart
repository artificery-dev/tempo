import 'dart:async';

import 'package:tempo_core/tempo_core.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The browser walks a filesystem in columns, and the wheel is the only
/// thing driving it - so what matters is that opening pushes a column,
/// menu takes it away, and every folder column starts with Back.
void main() {
  late MemoryFileSystem machine;
  late PlayerServices services;

  setUp(() {
    machine = MemoryFileSystem();
    for (final folder in const [
      '/root/Music/Albums',
      '/mnt/sd/Podcasts',
      '/etc',
    ]) {
      machine.directory(folder).createSync(recursive: true);
    }
    machine.file('/root/notes.txt').createSync();

    services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(const StorageReading(present: true)),
      places: ValueNotifier(Places(fileSystem: machine, home: '/root')),
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
    );
  });

  tearDown(() {
    FullFilesystem.enabled.value = false;
    FilesOptions.twoColumns.value = true;
  });

  Future<ClickWheelController> pumpFiles(
    WidgetTester tester, {
    UiScale scale = UiScale.regular,
  }) async {
    final wheel = ClickWheelController();
    final navigator = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      PlayerServicesScope(
        services: services,
        // At the player's own scale: the column widths are the panel's,
        // and rows at Tome's desktop paddings would not fit a trail.
        child: UiScaleScope(
          scale: scale,
          child: TomeApp(
            theme: scale.theme(Brightness.dark),
            debugShowCheckedModeBanner: false,
            navigatorKey: navigator,
            builder: (context, child) =>
                ClickWheelInput(controller: wheel, child: child!),
            // Pushed rather than the home, because leaving the app is one
            // of the things being tested.
            home: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    unawaited(navigator.currentState!.push(FilesScreen.route()));
    await tester.pumpAndSettle();
    return wheel;
  }

  testWidgets('the places are a list across the whole screen until one is '
      'opened, and columns from then on', (tester) async {
    final wheel = await pumpFiles(tester);
    final whole = tester.getSize(find.byType(FilesScreen)).width;
    expect(tester.getSize(find.byType(WheelList)).width, whole);

    // Home opens beside the places, which narrow into a trail.
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    final lists = find.byType(WheelList);
    expect(lists, findsNWidgets(2));
    // The trail on the left at its width, the working column against the
    // right edge at its own (the columns are painted back to front, so
    // by position rather than by order).
    final byLeft = [for (final e in lists.evaluate()) find.byWidget(e.widget)]
      ..sort(
        (a, b) => tester.getTopLeft(a).dx.compareTo(tester.getTopLeft(b).dx),
      );
    expect(tester.getSize(byLeft.first).width, FilesScreen.trailWidth);
    expect(tester.getSize(byLeft.last).width, FilesScreen.columnWidth);
    expect(tester.getTopRight(byLeft.last).dx, whole);

    // And back to the whole screen when it closes.
    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(WheelList)).width, whole);
  });

  testWidgets('the places are the leftmost column', (tester) async {
    await pumpFiles(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('SD Card'), findsOneWidget);
    // Not until it is asked for.
    expect(find.text('Root'), findsNothing);
    // No Back on the places: there is nothing behind them.
    expect(find.text('Back').hitTestable(), findsNothing);
  });

  testWidgets('opening a place pushes a column, menu takes it away', (
    tester,
  ) async {
    final wheel = await pumpFiles(tester);

    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    // Home's contents, beside the places rather than instead of them.
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);

    // Down into a folder, and a third column.
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('Albums'), findsOneWidget);

    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(find.text('Albums'), findsNothing);
    expect(find.text('Music'), findsOneWidget);
  });

  testWidgets('a folder column keeps Back and Options above its entries, '
      'scrolled off until the wheel goes up; Back closes it', (tester) async {
    final wheel = await pumpFiles(tester);

    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    // A folder opens onto its files: the nav rows are above the top edge,
    // and a lazy list does not even build what is off it.
    final columnTop = tester.getTopLeft(find.byType(WheelList).last).dy;
    final rowExtent = UiScale.regular.rowExtent;
    // The first entry's words sit in the first row (centerd in it).
    expect(tester.getTopLeft(find.text('Music')).dy, greaterThan(columnTop));
    expect(
      tester.getTopLeft(find.text('Music')).dy,
      lessThan(columnTop + rowExtent),
    );
    expect(find.text('Options').hitTestable(), findsNothing);
    expect(find.text('Back').hitTestable(), findsNothing);

    // One detent up brings Options down into view, one more Back.
    wheel.jog(-1);
    await tester.pumpAndSettle();
    expect(find.text('Options'), findsOneWidget);
    wheel.jog(-1);
    await tester.pumpAndSettle();
    expect(find.text('Back'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Back')).dy,
      lessThan(tester.getTopLeft(find.text('Options')).dy),
    );

    // And Back is one column closed.
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('Music'), findsNothing);
    expect(find.byType(FilesScreen), findsOneWidget);
  });

  testWidgets('Options opens the popover, and hiding dot-files hides them', (
    tester,
  ) async {
    addTearDown(() => FilesOptions.showHidden.value = false);
    machine.file('/root/.secret').createSync();
    final wheel = await pumpFiles(tester);
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('.secret'), findsNothing, reason: 'hidden by default');

    wheel.jog(-1);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.byType(FilesOptionsDialog), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);

    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('On'), findsOneWidget);
    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(find.byType(FilesOptionsDialog), findsNothing);
    expect(find.text('.secret'), findsOneWidget);
  });

  testWidgets('the places follow the debug option while the screen lives', (
    tester,
  ) async {
    await pumpFiles(tester);
    expect(find.text('Root'), findsNothing);
    FullFilesystem.enabled.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Root'), findsOneWidget);
    FullFilesystem.enabled.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Root'), findsNothing);
  });

  testWidgets('as an applet, Files remembers its open folders and its option', (
    tester,
  ) async {
    addTearDown(() => FilesOptions.showHidden.value = false);
    final store = AppletStore(services.places.value);
    final entry = systemMenu.at('/apps/files')!;
    // Written by a Files that was here before.
    Applet(entry: entry, store: store)
      ..state.set('open', ['/root/Music'])
      ..state.set('showHidden', true)
      ..state.flush();

    final applet = Applet(entry: entry, store: store);
    final wheel = ClickWheelController();
    await tester.pumpWidget(
      PlayerServicesScope(
        services: services,
        child: UiScaleScope(
          scale: UiScale.regular,
          child: TomeApp(
            theme: UiScale.regular.theme(Brightness.dark),
            debugShowCheckedModeBanner: false,
            builder: (context, child) =>
                ClickWheelInput(controller: wheel, child: child!),
            home: AppletScope(applet: applet, child: const FilesScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Music is open beside the places, and the option is as it was left.
    expect(find.byType(WheelList), findsNWidgets(2));
    expect(find.text('Albums'), findsOneWidget);
    expect(FilesOptions.showHidden.value, isTrue);

    // Closing it is remembered too.
    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    applet.state.flush();
    expect(
      Applet(entry: entry, store: store).state.get<List<Object?>>('open'),
      isEmpty,
    );
    applet.dispose();
  });

  testWidgets('menu from the first column leaves too', (tester) async {
    final wheel = await pumpFiles(tester);

    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(find.byType(FilesScreen), findsNothing);
  });

  testWidgets('reached from the dock: the wheel is on the places, the row '
      'under it wears the cursor, and menu opens the switcher', (tester) async {
    addTearDown(MenuDock.reset);
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel, services: services));
    await tester.pumpAndSettle();
    // The dock, four along to Files, and in.
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    wheel.jog(4 * MenuDock.physics.weight);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.byType(FilesScreen), findsOneWidget);
    expect(MenuDock.shown.value, isFalse);

    // The cursor is on Home; a detent moves it to SD Card.
    Finder cursor() => find.ancestor(
      of: find.byType(WheelList),
      matching: find.byType(FilesScreen),
    );
    bool wearsCursor(String label) => find
        .ancestor(of: find.text(label), matching: find.byType(DecoratedBox))
        .evaluate()
        .any(
          (e) =>
              ((e.widget as DecoratedBox).decoration as BoxDecoration).color ==
              ThemeProvider.of(e).widgets.surface
                  .resolve(SemanticSwatch.primary, SurfaceVariant.soft)
                  .fill,
        );
    expect(cursor(), findsOneWidget);
    expect(wearsCursor('Home'), isTrue);
    expect(wearsCursor('SD Card'), isFalse);
    wheel.jog(1);
    await tester.pumpAndSettle();
    expect(wearsCursor('SD Card'), isTrue);
    expect(wearsCursor('Home'), isFalse);

    // Menu at the root of the app is the switcher, and Files stays put
    // behind it.
    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(MenuDock.shown.value, isTrue);
    expect(find.byType(FilesScreen), findsOneWidget);
  });

  testWidgets('the trail marks the way in the neutral swatch', (tester) async {
    final wheel = await pumpFiles(tester);
    expect(find.byKey(FilesRowMark.key), findsNothing);

    // Into Home: Home - chosen in the places column, now the trail - wears
    // the neutral dress, not the primary the cursor wears in the working
    // column. (That the bar keeps saying Files is the dock test's: the
    // bar is the shell's, and there is no shell here.)
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    final mark = find.byKey(FilesRowMark.key);
    expect(mark, findsOneWidget);
    expect(
      find.descendant(of: mark, matching: find.text('Home')),
      findsOneWidget,
    );
    final element = mark.evaluate().single;
    final theme = ThemeProvider.of(element);
    final fill =
        ((element.widget as DecoratedBox).decoration as BoxDecoration).color;
    expect(
      fill,
      theme.widgets.surface
          .resolve(SemanticSwatch.neutral, SurfaceVariant.subtle)
          .fill,
    );
    expect(
      fill,
      isNot(
        theme.widgets.surface
            .resolve(SemanticSwatch.primary, SurfaceVariant.soft)
            .fill,
      ),
      reason: 'the trail is not a second cursor',
    );

    // Same box as the cursor, though: same corners, and - sitting inside
    // the row's own inset - the same width. It is one idea in two colors,
    // and two shapes on one screen would read as two.
    final decoration =
        (element.widget as DecoratedBox).decoration as BoxDecoration;
    expect(decoration.borderRadius, WheelRowDress.radiusOf(theme));
    final column = find.ancestor(of: mark, matching: find.byType(WheelList));
    expect(
      tester.getSize(mark).width,
      tester.getSize(column.first).width - UiScale.of(element).cardGap * 2,
      reason: 'the mark is not the width the cursor would be',
    );

    // Back out, and the mark goes with the trail.
    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(find.byKey(FilesRowMark.key), findsNothing);
  });

  testWidgets('the root shows up once it is allowed', (tester) async {
    FullFilesystem.enabled.value = true;
    await pumpFiles(tester);
    expect(find.text('Root'), findsOneWidget);
  });

  group('one column or two', () {
    /// Open a folder beside the places, and give back the lists in the
    /// order they sit across the screen.
    Future<List<Finder>> openOne(
      WidgetTester tester,
      ClickWheelController wheel,
    ) async {
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      final lists = find.byType(WheelList);
      return [for (final e in lists.evaluate()) find.byWidget(e.widget)]..sort(
        (a, b) => tester.getTopLeft(a).dx.compareTo(tester.getTopLeft(b).dx),
      );
    }

    testWidgets('two, at the sizes that have room for two', (tester) async {
      final wheel = await pumpFiles(tester);
      final whole = tester.getSize(find.byType(FilesScreen)).width;
      final byLeft = await openOne(tester, wheel);
      expect(tester.getSize(byLeft.last).width, FilesScreen.columnWidth);
      expect(tester.getSize(byLeft.last).width, lessThan(whole));
    });

    testWidgets('one at the large size, whatever the option says', (
      tester,
    ) async {
      expect(FilesOptions.twoColumns.value, isTrue);
      final wheel = await pumpFiles(tester, scale: UiScale.large);
      final whole = tester.getSize(find.byType(FilesScreen)).width;
      final byLeft = await openOne(tester, wheel);
      // The working column has the screen; the trail is off the left edge.
      expect(tester.getSize(byLeft.last).width, whole);
      expect(tester.getTopRight(byLeft.last).dx, whole);
      expect(FilesOptions.twoColumnsAt(UiScale.large), isFalse);
    });

    testWidgets('one below it too, when the option is turned off', (
      tester,
    ) async {
      final wheel = await pumpFiles(tester);
      final whole = tester.getSize(find.byType(FilesScreen)).width;
      final before = await openOne(tester, wheel);
      expect(tester.getSize(before.last).width, FilesScreen.columnWidth);

      FilesOptions.twoColumns.value = false;
      await tester.pumpAndSettle();
      final after =
          [
            for (final e in find.byType(WheelList).evaluate())
              find.byWidget(e.widget),
          ]..sort(
            (a, b) =>
                tester.getTopLeft(a).dx.compareTo(tester.getTopLeft(b).dx),
          );
      expect(tester.getSize(after.last).width, whole);
    });

    /// Open a folder, then its Options card. Options is the second of the
    /// rows every folder column starts with, scrolled off above the
    /// entries until the wheel goes up for it.
    Future<void> openOptions(
      WidgetTester tester,
      ClickWheelController wheel,
    ) async {
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(-1);
      await tester.pump();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
    }

    testWidgets('the option is on the card below the large size', (
      tester,
    ) async {
      await openOptions(tester, await pumpFiles(tester));
      expect(find.text('Columns'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('Show hidden files'), findsOneWidget);
    });

    testWidgets('and is not on it at the large size, where it could not be '
        'answered', (tester) async {
      await openOptions(tester, await pumpFiles(tester, scale: UiScale.large));
      expect(find.text('Show hidden files'), findsOneWidget);
      expect(find.text('Columns'), findsNothing);
    });

    testWidgets('a size with no room for two does not offer the choice', (
      tester,
    ) async {
      expect(FilesOptions.fitsTwoColumns(UiScale.compact), isTrue);
      expect(FilesOptions.fitsTwoColumns(UiScale.regular), isTrue);
      expect(FilesOptions.fitsTwoColumns(UiScale.large), isFalse);
    });
  });
}
