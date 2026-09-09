import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:tomeui/tomeui.dart';

import 'services/services.dart';
import 'status.dart';

/// The battery as a picture: an outlined cell with a terminal, its field
/// filled in five bars to the level - red for the last bar, yellow for the
/// second, green from the third up - and, against the cell's flat end,
/// the percent if asked, or the bolt while the charger is on: one slot,
/// and the bolt takes the digits' place so the cell can be wide enough
/// for its bars to read.
///
/// Sized by [height]; the width follows (the slot, the cell, the
/// terminal). Painted, not composed: at the bar's size a composed battery
/// would be three widgets fighting over four pixels.
class BatteryGauge extends StatelessWidget {
  const BatteryGauge({
    this.height,
    this.showPercent = true,
    this.color,
    super.key,
  });

  /// The cell's height; the bar's glyph size when null.
  final double? height;

  /// Set the percent, as bare digits, against the cell's flat end. Off,
  /// the field's bars are the whole reading.
  final bool showPercent;

  /// The outline (and the digits, and the bolt); the text color when
  /// null, so the gauge wears whatever the bar around it does.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final h = height ?? statusGlyphSize(theme);
    // The digits are part of the glyph, not a reading beside it: the
    // reading's mono and weight, but no taller than the cell.
    final style = readingStyle(theme).copyWith(fontSize: h * 0.85);

    return ValueListenableBuilder(
      valueListenable: PlayerServicesScope.of(context).battery,
      builder: (context, battery, _) {
        // On the charger the bolt has the slot; otherwise the digits, if
        // asked. The slot is as wide as its tenant: the digits measured,
        // so "5" and "100" each get exactly their room, the bolt its
        // fixed share.
        final percent =
            !battery.charging && showPercent && battery.percent != null
            ? '${battery.percent}'
            : null;
        final leading = battery.charging
            ? BatteryGaugePainter.boltSlot(h)
            : percent == null
            ? 0.0
            : BatteryGaugePainter.digitsWidth(percent, style) +
                  BatteryGaugePainter.gap(h);
        final painter = BatteryGaugePainter(
          reading: battery,
          outline: color ?? theme.palette.text,
          levels: BatteryLevels.of(theme),
          percent: percent,
          percentStyle: style,
          leading: leading,
        );
        return CustomPaint(
          size: Size(BatteryGaugePainter.widthFor(h, leading), h),
          painter: painter,
        );
      },
    );
  }
}

/// The three colors the field can be.
class BatteryLevels {
  const BatteryLevels({
    required this.low,
    required this.middling,
    required this.good,
  });

  /// The palette's error, warning and success, at their mid step.
  factory BatteryLevels.of(Theme theme) => BatteryLevels(
    low: theme.palette.error.s500,
    middling: theme.palette.warning.s500,
    good: theme.palette.success.s500,
  );

  final Color low;
  final Color middling;
  final Color good;
}

/// Draws the gauge. The arithmetic is here too, as plain functions, so a
/// test can ask what a level comes to without painting.
class BatteryGaugePainter extends CustomPainter {
  const BatteryGaugePainter({
    required this.reading,
    required this.outline,
    required this.levels,
    required this.percent,
    required this.percentStyle,
    required this.leading,
  });

  final BatteryReading reading;
  final Color outline;
  final BatteryLevels levels;

  /// The digits set before the cell, or null for none (on the charger
  /// the bolt stands there instead).
  final String? percent;
  final TextStyle percentStyle;

  /// The width of the slot before the cell: the digits and their gap, or
  /// the bolt and its.
  final double leading;

  /// The field is five bars, a fifth of the charge each.
  static const bars = 5;

  /// The cell is wider than it is tall by this much: room for five bars
  /// with a gap between each that still reads at the bar's size.
  static const cellRatio = 1.8;
  static const _terminalRatio = 0.14;

  /// The whole width for a height and the slot before the cell.
  static double widthFor(double height, double leading) =>
      leading + height * cellRatio + height * _terminalRatio;

  /// The breath between the digits (or the bolt) and the cell: close, so
  /// the parts read as one glyph.
  static double gap(double height) => height * 0.12;

  /// The room the bolt takes before the cell, gap included.
  static double boltSlot(double height) => height * 0.62 + gap(height);

  /// How many of the five bars a level lights: a fifth each, rounded up so
  /// that anything above empty shows one, and 100 shows all. Null (no
  /// reading) lights none.
  static int litBars(int? percent) {
    if (percent == null || percent <= 0) return 0;
    return (percent.clamp(0, 100) / (100 / bars)).ceil();
  }

  /// The field's color for that many lit bars: red for one, yellow for
  /// two, green from three up.
  static Color fieldColor(BatteryLevels levels, int lit) => switch (lit) {
    <= 1 => levels.low,
    2 => levels.middling,
    _ => levels.good,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final stroke = math.max(1.0, h / 12);
    final cellWidth = h * cellRatio;
    final terminalWidth = h * _terminalRatio;
    final radius = Radius.circular(h / 6);

    // The digits, against the cell's flat end, centerd on the cell by
    // their ink rather than their line box: a line box has more room
    // above the baseline than digits use, so centring it sets the digits
    // high. Digits stand from the baseline to about 0.72 em, so their
    // middle is 0.36 em above it.
    if (percent != null) {
      final paragraph = _paragraph(percent!, percentStyle);
      final metrics = paragraph.computeLineMetrics();
      final baseline = metrics.isEmpty
          ? paragraph.height * 0.8
          : metrics.first.baseline;
      final middle = baseline - (percentStyle.fontSize ?? h) * 0.36;
      canvas.drawParagraph(paragraph, Offset(0, h / 2 - middle));
    }

    // The cell: an outlined rounded box, and the terminal nub standing off
    // its right side, a third of the height tall.
    final cell = Rect.fromLTWH(
      leading + stroke / 2,
      stroke / 2,
      cellWidth - stroke,
      h - stroke,
    );
    final outlinePaint = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawRRect(RRect.fromRectAndRadius(cell, radius), outlinePaint);
    final terminal = Rect.fromLTWH(
      leading + cellWidth,
      h * 0.33,
      terminalWidth,
      h * 0.34,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(terminal, Radius.circular(terminalWidth / 2)),
      Paint()..color = outline,
    );

    // The field: five bars inside the outline with a gap between, the lit
    // ones in the level's color.
    final lit = litBars(reading.percent);
    final inset = stroke * 1.5;
    final field = cell.deflate(inset);
    final barGap = math.max(1.0, h / 14);
    final barWidth = (field.width - barGap * (bars - 1)) / bars;
    final fill = Paint()..color = fieldColor(levels, lit);
    for (var i = 0; i < lit; i++) {
      final bar = Rect.fromLTWH(
        field.left + i * (barWidth + barGap),
        field.top,
        barWidth,
        field.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bar, Radius.circular(stroke)),
        fill,
      );
    }

    // The bolt, in the slot before the cell, while the charger is on.
    if (reading.charging) {
      canvas.drawPath(
        _bolt(Rect.fromLTWH(0, 0, h * 0.62, h)),
        Paint()..color = outline,
      );
    }
  }

  /// How wide [text] paints: measured with the very paragraph the painter
  /// draws. A TextPainter with the same style came out a hair narrower on
  /// the device, and "71" wrapped onto two lines.
  static double digitsWidth(String text, TextStyle style) =>
      _build(text, style, const Color(0xFF000000)).longestLine;

  ui.Paragraph _paragraph(String text, TextStyle style) =>
      _build(text, style, outline);

  /// The digits on one line, however wide: laid out unconstrained and
  /// capped at one line, so the slot they are given can never wrap them -
  /// not "71", not "100".
  static ui.Paragraph _build(String text, TextStyle style, Color color) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: TextAlign.left,
              fontSize: style.fontSize,
              fontWeight: style.fontWeight,
              fontFamily: style.fontFamily,
              height: 1,
              maxLines: 1,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: color,
              fontSize: style.fontSize,
              fontWeight: style.fontWeight,
              fontFamily: style.fontFamily,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          )
          ..addText(text);
    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  /// A lightning bolt with lightly rounded tips, kept inside [box].
  static Path _bolt(Rect box) {
    Offset at(double x, double y) =>
        Offset(box.left + box.width * x, box.top + box.height * y);
    final corners = [
      at(0.62, 0),
      at(0.08, 0.58),
      at(0.46, 0.58),
      at(0.36, 1),
      at(0.92, 0.40),
      at(0.54, 0.40),
    ];
    final rounding = box.height * 0.04;
    final path = Path();
    for (var i = 0; i < corners.length; i++) {
      final corner = corners[i];
      final incoming =
          corners[(i + corners.length - 1) % corners.length] - corner;
      final outgoing = corners[(i + 1) % corners.length] - corner;
      final start = corner + incoming / incoming.distance * rounding;
      final end = corner + outgoing / outgoing.distance * rounding;
      if (i == 0) {
        path.moveTo(start.dx, start.dy);
      } else {
        path.lineTo(start.dx, start.dy);
      }
      path.quadraticBezierTo(corner.dx, corner.dy, end.dx, end.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(BatteryGaugePainter old) =>
      old.reading != reading ||
      old.outline != outline ||
      old.percent != percent ||
      old.leading != leading ||
      old.percentStyle != percentStyle ||
      old.levels.low != levels.low ||
      old.levels.middling != levels.middling ||
      old.levels.good != levels.good;
}
