import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/emulator/src/click_wheel_pad.dart';
import 'package:tempo_toolbox/emulator/src/wheel_motion.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

void main() {
  testWidgets('only the annular track captures wheel drags', (tester) async {
    final controller = ClickWheelController();
    final motion = WheelMotion(controller);
    addTearDown(motion.dispose);
    var frameDrags = 0;
    await tester.pumpWidget(
      TomeApp(
        home: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (_) => frameDrags++,
          child: Center(child: ClickWheelPad(diameter: 200, motion: motion)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(ClickWheelPad));
    final clip = tester.widget<ClipPath>(
      find.byWidgetPredicate(
        (w) => w is ClipPath && w.clipper is WheelTrackClipper,
      ),
    );
    final path = clip.clipper!.getClip(const Size(200, 200));
    expect(path.contains(const Offset(10, 10)), isFalse);
    expect(path.contains(const Offset(100, 100)), isFalse);
    expect(path.contains(const Offset(175, 100)), isTrue);

    // A start in a square corner passes through to the surrounding drag surface.
    await tester.dragFrom(origin + const Offset(5, 5), const Offset(35, 10));
    await tester.pumpAndSettle();
    expect(frameDrags, greaterThan(0));
    expect(motion.angle, 0);
    final previousFrameDrags = frameDrags;
    final gesture = await tester.startGesture(origin + const Offset(165, 60));
    await gesture.moveTo(origin + const Offset(180, 100));
    await gesture.moveTo(origin + const Offset(160, 155));
    await tester.pump();
    expect(motion.angle, isNot(0));
    expect(frameDrags, previousFrameDrags);
    final angle = motion.angle;
    await gesture.moveTo(origin + const Offset(100, 100));
    await gesture.moveTo(origin + const Offset(95, 105));
    await gesture.moveTo(origin + const Offset(200, 200));
    expect(motion.angle, angle);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
