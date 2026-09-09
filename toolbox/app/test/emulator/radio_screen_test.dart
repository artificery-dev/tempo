import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_core/src/settings/radio_screen.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

void main() {
  late Rig rig;
  late ClickWheelController wheel;
  setUp(() async {
    rig = Rig();
    await rig.initializeStorage();
    wheel = ClickWheelController();
  });
  tearDown(() {
    rig.dispose();
    SettingBindings.clear();
    SettingCapabilities.available.value = {};
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(480, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TomeApp(
        theme: Appearance.theme.value,
        home: PanelSurface(
          child: UiScaleScope(
            scale: UiScale.regular,
            child: PlayerServicesScope(
              services: rig.services,
              child: ClickWheelInput(
                controller: wheel,
                child: Navigator(
                  onGenerateRoute: (_) => PanelRoute(builder: (_) => page),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, int rows) async {
    for (var i = 0; i < rows; i++) {
      wheel.jog(1);
      await tester.pump();
    }
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
  }

  testWidgets('Wi-Fi power and known networks work with the wheel', (
    tester,
  ) async {
    await pump(tester, const RadioScreen());
    expect(find.text('Neon Bramble'), findsOneWidget);
    await choose(tester, 0);
    expect(rig.wifi.value.status, WifiStatus.off);
    await choose(tester, 0);
    expect(rig.wifi.value.status, WifiStatus.disconnected);
    await choose(tester, 2);
    expect(tester.widget<RadioScreen>(find.byType(RadioScreen)).known, isTrue);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Cafe Guest'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('password entry supports wheel characters and joins', (
    tester,
  ) async {
    await pump(tester, RadioNetworkScreen(network: rig.radios.networks.last));
    await choose(tester, 0);
    expect(find.text('0 characters entered'), findsOneWidget);
    await choose(tester, 2);
    for (var i = 0; i < 7; i++) {
      await choose(tester, 0);
    }
    expect(find.text('8 characters entered'), findsOneWidget);
    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    await choose(tester, 1);
    expect(rig.wifi.value.network, 'Moonbase');
    expect(find.text('Disconnect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bluetooth pair and forget are reflected in status', (
    tester,
  ) async {
    await rig.radios.enableBluetooth(false);
    await rig.radios.enableBluetooth(true);
    await pump(tester, RadioDeviceScreen(device: rig.radios.devices.last));
    await choose(tester, 0);
    expect(rig.bluetooth.value.device, 'Pocket Headphones');
    expect(find.text('Forget Device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'settings restore reads radio state and does not power services',
    () async {
      final settings = Settings(tree: playerSettingsTree);
      final bridge = PlayerSettings.install(settings, services: rig.services);
      addTearDown(bridge.detach);
      settings.set(
        '/settings/connections/wifi/enabled',
        false,
        source: SettingSource.system,
      );
      bridge.applyAll();
      await Future<void>.delayed(Duration.zero);
      expect(rig.wifi.value.status, WifiStatus.connected);
      expect(settings.value('/settings/connections/wifi/enabled'), true);
      await rig.radios.enableWifi(false);
      await Future<void>.delayed(Duration.zero);
      expect(settings.value('/settings/connections/wifi/enabled'), false);
    },
  );
}
