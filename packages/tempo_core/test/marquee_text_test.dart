import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// A panel this narrow cuts most sentences off, so the line under the
/// cursor walks itself past: out, a wait, back, and then it rests. A line
/// that fits, or one the wheel is not on, says what fits and stops.
void main() {
  Widget harness(Widget child, {double width = 100}) => TomeApp(
    debugShowCheckedModeBanner: false,
    home: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: width, child: child),
    ),
  );

  const long =
      'A description far too long to sit on one line of a panel '
      'this narrow, and so a candidate for walking past';

  double offsetOf(WidgetTester tester) {
    final transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(MarqueeText),
            matching: find.byType(Transform),
          )
          .first,
    );
    return transform.transform.getTranslation().x;
  }

  testWidgets('a line that fits is a plain, still line', (tester) async {
    await tester.pumpWidget(
      harness(const MarqueeText('Short', active: true), width: 300),
    );
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Text),
      ),
    );
    expect(text.overflow, TextOverflow.ellipsis);
    expect(find.byType(Transform), findsNothing, reason: 'nothing to walk');
  });

  testWidgets('a line the wheel is not on is ellipsized, and still', (
    tester,
  ) async {
    await tester.pumpWidget(harness(const MarqueeText(long)));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(Text),
      ),
    );
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('the line the wheel is on walks out, comes back, and rests', (
    tester,
  ) async {
    await tester.pumpWidget(harness(const MarqueeText(long, active: true)));
    await tester.pump();
    await tester.pump();
    expect(offsetOf(tester), 0, reason: 'it waits before it moves');

    // Out: the words slide to the left, so the offset goes negative.
    await tester.pump(MarqueeText.pause + const Duration(milliseconds: 600));
    final out = offsetOf(tester);
    expect(out, lessThan(0));

    // Further out, and never further than the words reach.
    await tester.pump(const Duration(milliseconds: 600));
    expect(offsetOf(tester), lessThan(out));

    // And it ends where it began, still, with no frames left to draw.
    await tester.pumpAndSettle();
    expect(offsetOf(tester), 0);
  });

  testWidgets('it stops when the wheel leaves the row, and starts over when '
      'it comes back', (tester) async {
    await tester.pumpWidget(harness(const MarqueeText(long, active: true)));
    await tester.pump();
    await tester.pump(MarqueeText.pause + const Duration(milliseconds: 600));
    expect(offsetOf(tester), lessThan(0));

    await tester.pumpWidget(harness(const MarqueeText(long)));
    await tester.pumpAndSettle();
    expect(
      find.byType(Transform),
      findsNothing,
      reason: 'back to a plain ellipsized line',
    );

    await tester.pumpWidget(harness(const MarqueeText(long, active: true)));
    await tester.pump();
    await tester.pump();
    expect(offsetOf(tester), 0, reason: 'from the beginning');
  });

  testWidgets('it is the same height walking as it is still: a row does not '
      'shift when the wheel lands on it', (tester) async {
    Rect boxOf() => tester.getRect(find.byType(MarqueeText));

    await tester.pumpWidget(harness(const MarqueeText(long)));
    await tester.pumpAndSettle();
    final still = boxOf();

    await tester.pumpWidget(harness(const MarqueeText(long, active: true)));
    await tester.pump();
    expect(boxOf().height, closeTo(still.height, 0.01));
    expect(boxOf().top, closeTo(still.top, 0.01));

    // And still the same height half way out.
    await tester.pump(MarqueeText.pause + const Duration(milliseconds: 600));
    expect(boxOf().height, closeTo(still.height, 0.01));
  });
}
