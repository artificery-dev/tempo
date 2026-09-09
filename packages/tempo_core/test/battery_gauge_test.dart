import 'package:tempo_core/tempo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

/// The gauge's arithmetic, and that it paints what the reading says: five
/// bars a fifth each, red-yellow-green by how many are lit, a bolt while
/// charging, the percent in the field when asked.
void main() {
  const levels = BatteryLevels(
    low: Color(0xFFFF0000),
    middling: Color(0xFFFFFF00),
    good: Color(0xFF00FF00),
  );

  test('a fifth of the charge lights a bar, rounded up', () {
    expect(BatteryGaugePainter.litBars(null), 0);
    expect(BatteryGaugePainter.litBars(0), 0);
    expect(BatteryGaugePainter.litBars(1), 1);
    expect(BatteryGaugePainter.litBars(20), 1);
    expect(BatteryGaugePainter.litBars(21), 2);
    expect(BatteryGaugePainter.litBars(40), 2);
    expect(BatteryGaugePainter.litBars(41), 3);
    expect(BatteryGaugePainter.litBars(60), 3);
    expect(BatteryGaugePainter.litBars(80), 4);
    expect(BatteryGaugePainter.litBars(81), 5);
    expect(BatteryGaugePainter.litBars(100), 5);
    expect(BatteryGaugePainter.litBars(140), 5, reason: 'clamped');
  });

  test('one bar is red, two yellow, three and up green', () {
    expect(BatteryGaugePainter.fieldColor(levels, 0), levels.low);
    expect(BatteryGaugePainter.fieldColor(levels, 1), levels.low);
    expect(BatteryGaugePainter.fieldColor(levels, 2), levels.middling);
    expect(BatteryGaugePainter.fieldColor(levels, 3), levels.good);
    expect(BatteryGaugePainter.fieldColor(levels, 5), levels.good);
  });

  test('the slot before the cell is as wide as what is in it', () {
    final bare = BatteryGaugePainter.widthFor(10, 0);
    expect(
      BatteryGaugePainter.widthFor(10, BatteryGaugePainter.boltSlot(10)),
      greaterThan(bare),
    );
    expect(BatteryGaugePainter.widthFor(10, 7), bare + 7);
    // The cell is wide enough for its five bars to read.
    expect(BatteryGaugePainter.cellRatio, greaterThanOrEqualTo(1.5));
  });

  Future<BatteryGaugePainter> pumpGauge(
    WidgetTester tester,
    BatteryReading reading, {
    bool showPercent = true,
  }) async {
    final services = PlayerServices(
      battery: ValueNotifier(reading),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: PlayerServices.fallback.places,
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
    );
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: PlayerServicesScope(
          services: services,
          child: Center(
            child: BatteryGauge(height: 12, showPercent: showPercent),
          ),
        ),
      ),
    );
    await tester.pump();
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(BatteryGauge),
        matching: find.byType(CustomPaint),
      ),
    );
    return paint.painter! as BatteryGaugePainter;
  }

  testWidgets('the widget paints the reading, in the theme\'s colors', (
    tester,
  ) async {
    final painter = await pumpGauge(
      tester,
      const BatteryReading(percent: 15, charging: true),
    );
    final theme = ThemeProvider.of(tester.element(find.byType(BatteryGauge)));
    expect(painter.reading.charging, isTrue);
    expect(painter.outline, theme.palette.text);
    expect(painter.levels.low, theme.palette.error.s500);
    expect(painter.levels.good, theme.palette.success.s500);
    // Charging: the bolt takes the slot before the cell, in the digits'
    // place.
    expect(painter.percent, isNull);
    expect(painter.leading, BatteryGaugePainter.boltSlot(12));
    expect(
      tester.getSize(find.byType(BatteryGauge)).width,
      BatteryGaugePainter.widthFor(12, painter.leading),
    );

    // Not charging: the digits stand there instead, no taller than the
    // cell.
    final quiet = await pumpGauge(tester, const BatteryReading(percent: 15));
    expect(quiet.percent, '15');
    expect(quiet.leading, greaterThan(BatteryGaugePainter.gap(12)));
    expect(quiet.percentStyle.fontSize, lessThan(12));

    // Asked to keep quiet: nothing before the cell at all.
    final bars = await pumpGauge(
      tester,
      const BatteryReading(percent: 15),
      showPercent: false,
    );
    expect(bars.percent, isNull);
    expect(bars.leading, 0);

    // It paints without complaint at the bar's size, percent and bolt and
    // all - and again with nothing to say.
    await tester.pumpAndSettle();
    await pumpGauge(tester, BatteryReading.unknown, showPercent: false);
    expect(tester.takeException(), isNull);
  });
}
