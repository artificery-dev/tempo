import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/src/dialog_list.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

void main() {
  testWidgets(
    'wheel and touch scroll the entire tall dialog, including its title',
    (tester) async {
      tester.view.physicalSize = const Size(480, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final wheel = ClickWheelController();
      final focus = FocusScopeNode();
      await tester.pumpWidget(
        TomeApp(
          builder: (context, child) =>
              ClickWheelInput(controller: wheel, child: child!),
          home: Builder(
            builder: (context) => Center(
              child: Button(
                center: const Text('Show'),
                onPressed: () {
                  showDialog<void>(
                    context,
                    builder: (_) => Dialog(
                      title: const Text('App actions'),
                      content: FocusScope(
                        node: focus,
                        child: DialogList(
                          onActivate: (_) {},
                          children: [
                            for (var i = 0; i < 10; i++) Text('Option $i'),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pumpAndSettle();
      final originalTitle = tester.getTopLeft(find.text('App actions')).dy;
      final cardHeight = tester.getSize(find.byType(Dialog)).height;
      expect(cardHeight, greaterThan(240));
      final listScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(WheelList),
          matching: find.byType(Scrollable),
        ),
      );
      expect(listScroll.position.maxScrollExtent, 0);

      wheel.jog(9);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('App actions')).dy, lessThan(0));
      expect(
        tester.getRect(find.text('Option 9')).bottom,
        lessThanOrEqualTo(240),
      );
      expect(listScroll.position.pixels, 0);
      expect(tester.getSize(find.byType(Dialog)).height, cardHeight);

      wheel.jog(-9);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('App actions')).dy,
        closeTo(originalTitle, 0.1),
      );
      await tester.dragFrom(const Offset(240, 160), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('App actions')).dy,
        lessThan(originalTitle),
      );
      expect(listScroll.position.pixels, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
  );
}
