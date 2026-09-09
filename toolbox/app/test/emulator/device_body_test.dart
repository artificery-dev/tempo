import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import 'package:flutter/gestures.dart';
import 'package:tempo_toolbox/emulator/emulator.dart';
import 'package:tempo_toolbox/emulator/src/click_wheel_pad.dart';
import 'package:tempo_toolbox/emulator/src/device_body.dart';
import 'package:tempo_toolbox/emulator/src/emulator_window.dart';
import 'package:tempo_toolbox/emulator/src/wheel_motion.dart';

/// The emulator's whole reason to exist: a press on the drawn wheel has to
/// reach the player's UI, which is a different app's widget tree nested
/// inside this one's. Nothing about that is free - the desktop's focus sits
/// in the emulator's chrome, not in the player - so it is worth a test.
void main() {
  late Rig rig;
  setUp(() async {
    rig = Rig();
    await rig.initializeStorage();
  });
  tearDown(() => rig.dispose());
  tearDown(() {
    MenuDock.reset();
    MenuDock.selected.value = null;
  });

  Future<void> pumpDevice(
    WidgetTester tester,
    ClickWheelController wheel,
  ) async {
    final motion = WheelMotion(wheel);
    addTearDown(motion.dispose);

    // A window big enough for the body at 1x on a 96dpi assumption.
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: DeviceBody(
          services: rig.services,
          window: EmulatorWindow(),
          motion: motion,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the body fits the first frame before the host resizes', (
    tester,
  ) async {
    final window = EmulatorWindow();
    final wheel = ClickWheelController();
    final motion = WheelMotion(wheel);
    addTearDown(motion.dispose);
    addTearDown(window.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(370.2, 573);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: Center(
          child: ListenableBuilder(
            listenable: window,
            builder: (context, _) => DeviceBody(
              services: rig.services,
              window: window,
              motion: motion,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final panel = tester.element(find.byType(PanelSurface));

    // The native window catches up without replacing the player's state.
    tester.view.physicalSize = window.geometry.size + const Offset(40, 40);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.element(find.byType(PanelSurface)), same(panel));
    expect(
      tester.getSize(find.byType(ClickWheelPad)).width,
      window.geometry.wheel,
    );

    // Zoom changes rebuild before the native resize arrives too.
    window.restoreZoom(3);
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = window.geometry.size + const Offset(40, 40);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.element(find.byType(PanelSurface)), same(panel));
  });

  testWidgets(
    'outer side-button surface responds and body drag excludes controls',
    (tester) async {
      final wheel = ClickWheelController();
      final motion = WheelMotion(wheel);
      final window = EmulatorWindow(managesWindow: false);
      addTearDown(motion.dispose);
      addTearDown(window.dispose);
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var drags = 0;
      await tester.pumpWidget(
        TomeApp(
          home: Center(
            child: DeviceBody(
              services: rig.services,
              window: window,
              motion: motion,
              onDrag: () => drags++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = tester.getRect(find.byIcon(LucideIcons.plus));
      final before = rig.volume.value.level;
      await tester.tapAt(Offset(button.right - 0.5, button.center.dy));
      await tester.pump();
      expect(rig.volume.value.level, greaterThan(before));
      expect(drags, 0);
      await tester.tapAt(tester.getCenter(find.byType(ClickWheelPad)));
      await tester.pumpAndSettle();
      expect(drags, 0);
      final panel = tester.getRect(find.byType(PanelSurface));
      await tester.tapAt(panel.topLeft - const Offset(5, 5));
      expect(drags, 1);
      VolumeOsd.hide();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the home screen shows inside the body', (tester) async {
    await pumpDevice(tester, ClickWheelController());
    expect(find.byType(PanelSurface), findsOneWidget);
    // And nothing the player draws leaves the glass: the covers in the
    // dock's flow reach past the panel, and stop at its edge.
    expect(
      find.ancestor(
        of: find.byType(PanelSurface),
        matching: find.byType(ClipRect),
      ),
      findsWidgets,
    );
    // The ring's north slot, as the hardware prints it.
    expect(find.byIcon(LucideIcons.undo2), findsOneWidget);
    expect(find.byIcon(LucideIcons.layoutGrid), findsOneWidget);
  });

  testWidgets('the menu button on the ring brings up the dock', (tester) async {
    final wheel = ClickWheelController();
    await pumpDevice(tester, wheel);

    expect(find.byType(WheelRail<MenuLocation>), findsNothing);
    await tester.tap(find.byIcon(LucideIcons.undo2));
    await tester.pumpAndSettle();

    expect(find.byType(WheelRail<MenuLocation>), findsOneWidget);
  });

  testWidgets('the center button brings it up too, and menu puts it away', (
    tester,
  ) async {
    final wheel = ClickWheelController();
    await pumpDevice(tester, wheel);

    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.byType(WheelRail<MenuLocation>), findsOneWidget);

    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(find.byType(WheelRail<MenuLocation>), findsNothing);
  });

  testWidgets('the wheel still reaches the player when the chrome has focus', (
    tester,
  ) async {
    final wheel = ClickWheelController();
    final motion = WheelMotion(wheel);
    addTearDown(motion.dispose);
    final chrome = FocusNode(debugLabel: 'chrome');
    addTearDown(chrome.dispose);

    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: Column(
          children: [
            // Stand in for the emulator's title bar: something outside the
            // player that the desktop's focus can land on.
            Focus(focusNode: chrome, child: const SizedBox(height: 20)),
            Expanded(
              child: DeviceBody(
                services: rig.services,
                window: EmulatorWindow(),
                motion: motion,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    chrome.requestFocus();
    await tester.pumpAndSettle();
    expect(primaryFocus, chrome);

    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.byType(WheelRail<MenuLocation>), findsOneWidget);
  });

  testWidgets('turning the wheel walks the menu', (tester) async {
    final wheel = ClickWheelController();
    await pumpDevice(tester, wheel);

    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();

    // Along the dock to 'Apps', then in: a level of its own, with Files
    // in it.
    wheel.jog(MenuDock.physics.weight);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Store'), findsOneWidget);

    // Down to 'Store', then in: the placeholder screen names it.
    wheel.jog(2);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();

    expect(find.text('nothing here yet - menu goes back'), findsOneWidget);
    expect(find.text('/apps/store'), findsOneWidget);
  });
  testWidgets('a scroll anywhere over the emulator turns the wheel', (
    tester,
  ) async {
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

    // Over the screen itself, which on this device has no touch panel and
    // no scrollable the wheel has to argue with.
    final glass = tester.getCenter(find.byType(PanelSurface));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(glass));

    // Home ignores the wheel on purpose, so the dock is what proves a jog
    // arrived: bring it up, scroll along it to Apps, and in.
    await tester.tap(find.byIcon(LucideIcons.undo2));
    await tester.pumpAndSettle();
    // Detent after detent, as a thumb would - not with a rest between
    // each, which would let the box spring back.
    for (var i = 0; i < MenuDock.physics.weight; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wheel.center')));
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget, reason: 'Apps opened');

    // Two more scrolls walk past FM Radio to Store; the center proves it.
    for (var i = 0; i < 2; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wheel.center')));
    await tester.pumpAndSettle();
    expect(find.text('/apps/store'), findsOneWidget);
  });

  testWidgets('a jog on the home screen is the volume', (tester) async {
    final wheel = ClickWheelController();
    await pumpDevice(tester, wheel);

    // Nothing to walk on home: the turn moves the level and shows it.
    wheel.jog(1);
    await tester.pump(VolumeOsd.fade);
    await tester.pump(VolumeOsd.fade);
    await tester.pump();
    expect(find.text('Home'), findsNothing);
    expect(find.byKey(VolumeOsd.cardKey), findsOneWidget);
    // The card shows the level as a bar rather than a number.
    expect(find.byKey(OsdBar.fillKey), findsOneWidget);
    expect(find.text('55'), findsNothing);
    final lit = tester.getSize(find.byKey(OsdBar.fillKey)).width;

    // Turning the other way takes the level down, and the bar with it.
    wheel.jog(-3);
    await tester.pump();
    expect(tester.getSize(find.byKey(OsdBar.fillKey)).width, lessThan(lit));

    // Put it away before the test ends: its clock is a pending timer. That
    // it leaves the tree is the core suite's to check.
    VolumeOsd.hide();
    await tester.pumpAndSettle();
  });

  testWidgets('the wheel lights where it was turned, and fades', (
    tester,
  ) async {
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

    double glow() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(WheelGlow),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    expect(glow(), 0, reason: 'a wheel at rest is not lit');

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byType(WheelGlow))),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
    await tester.pump();

    expect(glow(), 1, reason: 'turning it lights it');

    // And it goes out on its own once the wheel is left alone.
    await tester.pump(const Duration(seconds: 1));
    expect(glow(), 0);
    await tester.pumpAndSettle();
  });

  testWidgets('the buttons answer a pointer resting on them', (tester) async {
    final wheel = ClickWheelController();
    await pumpDevice(tester, wheel);

    const centerKey = ValueKey('wheel.center');
    Color center() {
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byKey(centerKey),
          matching: find.byType(Container),
        ),
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    final resting = center();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(centerKey)));
    await tester.pumpAndSettle();

    final hovered = center();
    expect(hovered, isNot(resting), reason: 'a pointer over it shows');

    await mouse.down(tester.getCenter(find.byKey(centerKey)));
    await tester.pumpAndSettle();
    expect(center(), isNot(hovered), reason: 'and pushing it shows harder');

    await mouse.up();
    await tester.pumpAndSettle();
  });
}
