// The application pins the SDK providing these native window APIs.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:tomeui/tomeui.dart';
import 'package:tempo_toolbox/emulator/emulator.dart';
import 'package:tempo_toolbox/emulator/src/emulator_window.dart';
import 'package:tempo_toolbox/emulator/src/hardware.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:flutter/src/widgets/_window.dart' as native;
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/emulator/launcher_native.dart';

class TestWindow extends ChangeNotifier implements native.WindowController {
  int activations = 0;
  @override
  bool isDestroyed = false;
  @override
  void activate() => activations++;
  @override
  void destroy() {
    isDestroyed = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('MCP screen text stays scoped to the emulator in a shared tree', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = Rig();
    await rig.initializeStorage();
    addTearDown(rig.dispose);
    final window = EmulatorWindow(managesWindow: false);
    addTearDown(window.dispose);
    await tester.pumpWidget(
      TomeApp(
        home: Column(
          children: [
            const Text('Toolbox-only sentinel'),
            Expanded(
              child: EmulatorApp(window: window, rig: rig),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(EmulatorHardware.running, isTrue);
    EmulatorHardware.pressNamed('select');
    await tester.pumpAndSettle();
    expect(EmulatorHardware.screenText(), contains('Home'));
    expect(
      EmulatorHardware.screenText(),
      isNot(contains('Toolbox-only sentinel')),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(EmulatorHardware.running, isFalse);
    expect(EmulatorHardware.screenText(), isEmpty);
  });

  test('open reuses the native window; closing allows a new popout window', () {
    final created = <TestWindow>[];
    final windows = DesktopEmulatorWindows(
      createWindow: () {
        final window = TestWindow();
        created.add(window);
        return window;
      },
    );
    var notifications = 0;
    windows.addListener(() => notifications++);
    windows.open();
    expect(created, hasLength(1));
    expect(windows.window, same(created.single));
    expect(created.single.activations, 1);
    windows.open();
    expect(created, hasLength(1));
    expect(created.single.activations, 2);
    created.single.destroy();
    expect(windows.window, isNull);
    windows.open();
    expect(created, hasLength(2));
    expect(windows.window, same(created.last));
    expect(notifications, 3);
    windows.dispose();
    expect(created.last.isDestroyed, isTrue);
  });
}
