import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' as io;

import 'package:tempo_core/tempo_core.dart';
import 'package:file/file.dart' show FileSystemEntityType;
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import 'package:tempo_toolbox/emulator/emulator.dart';
import 'package:tempo_toolbox/emulator/src/device_body.dart';
import 'package:tempo_toolbox/emulator/src/emulator_window.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:tempo_toolbox/emulator/src/wheel_motion.dart';

/// The rig is only worth having if moving it moves the player: these check
/// the whole path, from a setter on the rig to the glyph on the panel.
void main() {
  late Rig rig;

  setUp(() async {
    rig = Rig();
    await rig.initializeStorage();
  });
  tearDown(() {
    MenuDock.reset();
    MenuDock.selected.value = null;
  });
  tearDown(() => rig.dispose());

  Future<void> pumpDevice(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final motion = WheelMotion(ClickWheelController());
    addTearDown(motion.dispose);

    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: DeviceBody(
          window: EmulatorWindow(),
          motion: motion,
          services: rig.services,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the battery reads what the rig is set to', (tester) async {
    await pumpDevice(tester);
    // The bar's battery is painted; the painter carries the reading.
    BatteryReading painted() =>
        (tester
                    .widget<CustomPaint>(
                      find.descendant(
                        of: find.byType(BatteryGauge),
                        matching: find.byType(CustomPaint),
                      ),
                    )
                    .painter!
                as BatteryGaugePainter)
            .reading;
    expect(painted().percent, 78);

    rig.setCharge(3);
    await tester.pump();
    expect(painted().percent, 3);

    // The charger adds its bolt rather than a second reading.
    rig.setCharging(true);
    await tester.pump();
    expect(painted().charging, isTrue);
    expect(painted().percent, 3);
  });

  testWidgets('the rig updates every Wi-Fi icon state', (tester) async {
    await pumpDevice(tester);
    WifiStatusIcon painted() =>
        tester.widget<WifiStatusIcon>(find.byType(WifiStatusIcon));
    expect(painted().status, WifiStatus.connected);
    rig.setBars(1);
    await tester.pump();
    expect(painted().bars, 1);
    rig.setWifi(WifiStatus.disconnected);
    await tester.pump();
    expect(painted().status, WifiStatus.disconnected);
    rig.setWifi(WifiStatus.off);
    await tester.pump();
    expect(find.byType(WifiStatusIcon), findsNothing);
  });

  testWidgets('the rig updates every Bluetooth icon state', (tester) async {
    await pumpDevice(tester);
    BluetoothStatusPainter painted() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<BluetoothStatusPainter>()
        .single;
    expect(painted().status, BluetoothStatus.connected);
    rig.setBluetooth(BluetoothStatus.on);
    await tester.pump();
    expect(painted().status, BluetoothStatus.on);
    rig.setBluetooth(BluetoothStatus.off);
    await tester.pump();
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<BluetoothStatusPainter>(),
      isEmpty,
    );
  });

  testWidgets('the card comes and goes with the slot', (tester) async {
    await pumpDevice(tester);
    // An empty slot is where the rig starts, and the card it will offer is
    // a made-up one: nothing on this machine is touched until asked.
    expect(find.byIcon(LucideIcons.hardDrive), findsNothing);
    expect(rig.cardInserted, isFalse);
    expect(rig.cardSource, CardSource.inMemory);
    expect(rig.storage.value, StorageReading.empty);

    rig.cardInserted = true;
    await tester.pump();
    expect(rig.storage.value.label, 'Emulated card');
    expect(rig.storage.value.path, isNull, reason: 'in-memory has no root');

    // Changing what stands behind the card while it is in the slot is an
    // eject and an insert, in that order.
    final readings = <StorageReading>[];
    rig.storage.addListener(() => readings.add(rig.storage.value));
    rig.cardSource = CardSource.hostFolder;
    expect(readings.map((r) => r.present), [false, true]);
    readings.clear();
    rig.hostFolder = '/home/you/Music';
    expect(readings.map((r) => r.present), [false, true]);
    await tester.pump();
    expect(rig.storage.value.path, '/home/you/Music');
    expect(rig.storage.value.label, 'Music');

    rig.cardInserted = false;
    await tester.pump();
    expect(rig.storage.value, StorageReading.empty);
  });

  testWidgets('the rig opens over the device, with the card sources spelled '
      'out', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: ProviderScope(child: EmulatorShell(window: EmulatorWindow())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Emulated Device State'), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();

    expect(find.text('Emulated Device State'), findsOneWidget);

    expect(
      find.byKey(const ValueKey('emulator-section-Battery')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('emulator-section-Wi-Fi')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('emulator-section-SD card')),
      findsOneWidget,
    );
    // The screen's switch is a hand on the sleep clock, not the backlight.
    expect(find.text('Stay awake'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('emulator-section-SD card')));
    await tester.pumpAndSettle();
    // Both sources, each saying what choosing it means.
    expect(find.text('In-Memory'), findsOneWidget);
    expect(find.text('Host Folder'), findsOneWidget);
    expect(find.textContaining('A card the emulator makes up'), findsOneWidget);
    expect(find.textContaining('A directory on this machine'), findsOneWidget);

    // And it is a modal: the player is still behind it.
    expect(find.byType(PanelSurface), findsOneWidget);

    // The button that opened it closes it - one rig, not one per press.
    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(find.text('Emulated Device State'), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(find.text('Emulated Device State'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(find.text('Emulated Device State'), findsNothing);

    // Closing preserves the toggle: the next press opens again.
    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(find.text('Emulated Device State'), findsOneWidget);
  });

  test('the card is mounted into the machine where the device mounts it', () {
    // The made-up card: the one whose contents the test can speak for.
    rig.cardSource = CardSource.inMemory;
    rig.cardInserted = true;
    final machine = rig.places.value;
    expect(machine.sdCard, '/mnt/sd');
    expect(machine.home, '/home/tempo');

    // Something on the card, so a browser has something to show.
    final card = machine.fileSystem.directory('/mnt/sd');
    expect(card.childDirectory('Music').existsSync(), isTrue);

    // And it is a card: what is written stays between insertions.
    machine.fileSystem.file('/mnt/sd/Music/track.mp3').createSync();
    rig.cardInserted = false;
    expect(
      rig.places.value.fileSystem.directory('/mnt/sd').existsSync(),
      isFalse,
      reason: 'no card, no mount',
    );

    rig.cardInserted = true;
    expect(
      rig.places.value.fileSystem.file('/mnt/sd/Music/track.mp3').existsSync(),
      isTrue,
    );
  });

  test('the machine around the card is a machine', () {
    final fs = rig.places.value.fileSystem;
    expect(fs.file('/etc/hostname').readAsStringSync().trim(), 'tempo');
    expect(
      fs.directory('/').listSync().map((e) => e.path),
      containsAll(<String>['/etc', '/mnt', '/home', '/root']),
    );
  });

  test('a host folder is mounted, not chrooted away', () {
    final temp = io.Directory.systemTemp.createTempSync('tempo-card');
    addTearDown(() => temp.deleteSync(recursive: true));
    io.File('${temp.path}/song.flac').createSync();

    rig.cardSource = CardSource.hostFolder;
    rig.hostFolder = temp.path;
    rig.cardInserted = true;

    final fs = rig.places.value.fileSystem;
    // The folder's contents appear at the mount point, wearing the
    // machine's paths rather than the host's.
    expect(fs.file('/mnt/sd/song.flac').existsSync(), isTrue);
    expect(fs.directory('/mnt/sd').listSync().single.path, '/mnt/sd/song.flac');

    // Written through the machine, landing in the real folder.
    fs.file('/mnt/sd/written.txt').writeAsStringSync('hello');
    expect(io.File('${temp.path}/written.txt').existsSync(), isTrue);

    // And the host above the folder is not reachable through the mount.
    expect(fs.file('/mnt/sd/../../etc/hostname').existsSync(), isTrue);
    expect(fs.typeSync('/mnt/sd/..'), FileSystemEntityType.directory);
  });

  testWidgets('the appearance control dresses both UIs', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => Appearance.mode.value = AppearanceMode.dark);

    await tester.pumpWidget(EmulatorApp(window: EmulatorWindow(), rig: rig));
    await tester.pumpAndSettle();

    Brightness dressOf(Type app) =>
        ThemeProvider.of(tester.element(find.byType(app))).palette.brightness;

    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emulator-section-Appearance')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    // The emulator's own chrome, and the player inside it.
    expect(dressOf(EmulatorShell), Brightness.light);
    // Read from inside the home screen, below the palette it pins for
    // itself: the boot image is black in either light.
    expect(dressOf(BatteryGauge), Brightness.dark, reason: 'home is always');
    expect(dressOf(DeviceBody), Brightness.light);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(dressOf(EmulatorShell), Brightness.dark);
  });

  testWidgets('the player scale sizes its screens and leaves '
      'both chromes alone', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => Appearance.scale.value = UiScale.regular);

    await tester.pumpWidget(EmulatorApp(window: EmulatorWindow(), rig: rig));
    await tester.pumpAndSettle();

    double bodySizeAt(Finder finder) =>
        ThemeProvider.of(tester.element(finder)).typography.body.fontSize!;

    final stage = find.byKey(DockStage.stageKey);
    final clock = find.byType(ClockText);
    final shell = find.byType(EmulatorShell);

    // Three scales at once: the player's screens at the size it is set to,
    // the player's own chrome fixed, and the emulator's chrome at the
    // desktop's.
    expect(bodySizeAt(stage), UiScale.regular.typography.body.fontSize);
    expect(bodySizeAt(clock), chromeScale.typography.body.fontSize);
    expect(bodySizeAt(shell), const Typography().body.fontSize);

    // The emulator shares the player's scale, but doesn't expose a separate
    // scale control in its device-state sidebar.
    Appearance.scale.value = UiScale.large;
    await tester.pumpAndSettle();

    expect(Appearance.scale.value, UiScale.large);
    expect(bodySizeAt(stage), UiScale.large.typography.body.fontSize);
    expect(
      bodySizeAt(clock),
      chromeScale.typography.body.fontSize,
      reason: 'the clock on home is chrome, and keeps its size',
    );
    expect(bodySizeAt(shell), const Typography().body.fontSize);
  });
}
