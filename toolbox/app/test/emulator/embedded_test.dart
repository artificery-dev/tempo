import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:tempo_toolbox/emulator/src/rig_panel.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_toolbox/emulator/emulator.dart';
import 'package:tempo_toolbox/emulator/src/device_body.dart';
import 'package:tempo_toolbox/emulator/src/emulator_window.dart';
import 'package:tempo_toolbox/emulator/src/hardware.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:tomeui/tomeui.dart';

void main() {
  testWidgets(
    'presentation changes retain the player and rebind frame dragging',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rig = Rig();
      await rig.initializeStorage();
      final window = EmulatorWindow(managesWindow: false);
      final key = GlobalKey();
      var dragged = false;
      Widget host(bool expanded) => TomeApp(
        home: expanded
            ? Column(
                children: [
                  Expanded(
                    child: EmulatorApp(
                      key: key,
                      window: window,
                      rig: rig,
                      expandedControls: true,
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: EmulatorApp(
                      key: key,
                      window: window,
                      rig: rig,
                      onDrag: () => dragged = true,
                    ),
                  ),
                ],
              ),
      );
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('emulator-section-Appearance')),
        findsOneWidget,
      );
      expect(find.byType(DeviceBody), findsOneWidget);
      final player = tester.state(find.byType(TempoApp));
      EmulatorHardware.pressNamed('select');
      await tester.pumpAndSettle();
      expect(EmulatorHardware.screenText(), contains('Home'));
      expect(EmulatorHardware.screenText(), isNot(contains('Simulated state')));
      expect(EmulatorHardware.screenText(), isNot(contains('Screenshot')));
      rig.setCharge(37);
      await tester.pump();
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(TempoApp)), same(player));
      expect(rig.battery.value.percent, 37);
      final body = tester.widget<DeviceBody>(find.byType(DeviceBody));
      expect(body.onDrag, isNotNull);
      body.onDrag!();
      expect(dragged, isTrue);
      expect(
        find.byKey(const ValueKey('emulator-section-Appearance')),
        findsNothing,
      );
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(TempoApp)), same(player));
      expect(tester.widget<DeviceBody>(find.byType(DeviceBody)).onDrag, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      rig.dispose();
      window.dispose();
    },
  );

  testWidgets(
    'frame claims wheel input and surrounding space scrolls flush controls',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rig = Rig();
      await rig.initializeStorage();
      final window = EmulatorWindow(managesWindow: false);
      await tester.pumpWidget(
        EmulatorApp(window: window, rig: rig, expandedControls: true),
      );
      await tester.pumpAndSettle();
      // Controls begin closed; open them to exercise overflow scrolling.
      for (final title in [
        'Appearance',
        'Battery',
        'Screen',
        'FM Radio',
        'Wi-Fi',
        'Bluetooth',
        'SD card',
      ]) {
        final toggle = find.byKey(ValueKey('emulator-section-$title'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
      }
      final controls = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('emulator-expanded-controls')),
          )
          .controller!;
      controls.jumpTo(0);
      await tester.pumpAndSettle();
      final sidebar = tester.getRect(
        find.byKey(const ValueKey('emulator-controls-sidebar')),
      );
      final header = tester.getRect(
        find.byKey(const ValueKey('emulator-page-header')),
      );
      expect(sidebar.top, header.bottom);
      expect(sidebar.right, 1200);
      expect(sidebar.bottom, 900);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('emulator-expanded-controls')),
          )
          .controller!;
      final body = tester.widget<DeviceBody>(find.byType(DeviceBody));
      final angle = body.motion.angle;
      final frame = tester.getRect(
        find.byKey(const ValueKey('emulator-player-frame')),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: frame.topCenter + const Offset(0, 40),
          scrollDelta: const Offset(0, 100),
        ),
      );
      await tester.pumpAndSettle();
      expect(body.motion.angle, isNot(angle));
      expect(scroll.offset, 0);
      final afterJog = body.motion.angle;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: Offset(10, header.bottom + 30),
          scrollDelta: const Offset(0, 160),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 160);
      expect(body.motion.angle, afterJog);
      expect(
        tester.getRect(find.byKey(const ValueKey('emulator-page-header'))),
        header,
      );
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      final appearance = find.ancestor(
        of: find.byKey(const ValueKey('emulator-section-Appearance')),
        matching: find.byType(EmulatorControlCard),
      );
      final height = tester.getSize(appearance).height;
      await tester.tap(
        find.byKey(const ValueKey('emulator-section-Appearance')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final during = tester.getSize(appearance).height;
      await tester.pumpAndSettle();
      final closed = tester.getSize(appearance).height;
      expect(during, lessThan(height));
      expect(during, greaterThan(closed));
      rig.setCharge(37);
      await tester.pumpAndSettle();
      expect(tester.getSize(appearance).height, closed);
      await tester.tap(
        find.byKey(const ValueKey('emulator-section-Appearance')),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(appearance).height, height);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      rig.dispose();
      window.dispose();
    },
  );

  testWidgets('expanded controls fit a narrow mobile page', (tester) async {
    tester.view.physicalSize = const Size(288, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = Rig();
    await rig.initializeStorage();
    final window = EmulatorWindow(managesWindow: false);
    await tester.pumpWidget(
      EmulatorApp(
        window: window,
        rig: rig,
        expandedControls: true,
        onPopOut: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final label in ['Screenshot', 'Restart', 'Pop out']) {
      final button = find.byKey(ValueKey('emulator-action-$label'));
      final icon = find.descendant(of: button, matching: find.byType(Icon));
      expect(tester.getSize(icon), const Size(16, 16));
      expect(tester.getCenter(icon), tester.getCenter(button));
    }
    await tester.ensureVisible(
      find.byKey(const ValueKey('emulator-action-Screenshot')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    rig.dispose();
    window.dispose();
  });

  testWidgets('embedded size follows space and keeps the popout preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = Rig();
    await rig.initializeStorage();
    final window = EmulatorWindow(managesWindow: false)..restoreZoom(4);
    await tester.pumpWidget(
      EmulatorApp(window: window, rig: rig, expandedControls: true),
    );
    await tester.pumpAndSettle();
    final player = tester.state(find.byType(TempoApp));
    final largeZoom = tester.widget<DeviceBody>(find.byType(DeviceBody)).zoom!;
    expect(largeZoom, greaterThan(1));
    expect(find.text('Device zoom'), findsNothing);
    expect(find.text('Scale'), findsNothing);

    tester.view.physicalSize = const Size(900, 760);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DeviceBody>(find.byType(DeviceBody)).zoom,
      lessThan(largeZoom),
    );
    expect(tester.state(find.byType(TempoApp)), same(player));
    // A 1296×774 Toolbox body minus its 224px navigation sidebar.
    // 1.5× fits here; an extra 24px canvas inset incorrectly rejected it.
    tester.view.physicalSize = const Size(1072, 774);
    await tester.pumpAndSettle();
    expect(tester.widget<DeviceBody>(find.byType(DeviceBody)).zoom, 1.5);
    expect(tester.state(find.byType(TempoApp)), same(player));
    expect(window.zoom, 4);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    rig.dispose();
    window.dispose();
  });
}
