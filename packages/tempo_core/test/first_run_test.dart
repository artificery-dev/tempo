import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// First run, walked with the wheel from Welcome to the restart, over a
/// daemon that only records what it was asked.
void main() {
  late ClickWheelController wheel;
  late List<Map<String, Object?>> requests;
  late Settings settings;
  var finished = false;

  setUp(() {
    wheel = ClickWheelController();
    requests = [];
    settings = Settings(tree: playerSettingsTree);
    finished = false;
    SettingBindings.clear();
  });
  tearDown(() {
    SettingBindings.clear();
    Appearance.mode.value = AppearanceMode.dark;
    Appearance.scale.value = UiScale.regular;
  });

  Future<Map<String, Object?>> daemon(Map<String, Object?> request) async {
    requests.add(request);
    return switch (request['op']) {
      'first-run' when request['pending'] == null => {
        'ok': true,
        'done': false,
        'applied': <String, Object?>{},
      },
      'clock' when request['set'] == null => {
        'ok': true,
        'synchronized': false,
        'ntp': true,
        'now': 'Thu 2026-04-27 00:00:00 UTC',
      },
      _ => {'ok': true},
    };
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      FirstRunApp(
        services: PlayerServices.fallback,
        state: FirstRunState(request: daemon),
        settings: settings,
        wheel: wheel,
        onFinished: () => finished = true,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Walk [rows] rows (down, or up when negative) and throw the row.
  Future<void> choose(WidgetTester tester, int rows) async {
    for (var i = 0; i < rows.abs(); i++) {
      wheel.jog(rows.sign);
      await tester.pump();
    }
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
  }

  /// Types [text] on the keyboard from the lit key at [from], then Done.
  Future<void> type(WidgetTester tester, String text, {int from = 0}) async {
    final keys = KeyboardLayout.keys(KeyboardPage.lower);
    var at = from;
    for (final character in text.split('')) {
      final to = keys.indexOf(character);
      wheel.jog(to - at);
      await tester.pump();
      wheel.press(WheelButton.select);
      await tester.pump();
      at = to;
    }
    wheel.jog(keys.indexOf(KeyboardLayout.done) - at);
    await tester.pump();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
  }

  testWidgets('the whole way through, and what the machine is told', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('first-run-welcome')), findsOneWidget);
    await choose(tester, 0);
    expect(find.byKey(const ValueKey('first-run-language')), findsOneWidget);
    await choose(tester, 0);
    expect(find.byKey(const ValueKey('first-run-zone')), findsOneWidget);
    await choose(tester, 0); // UTC
    // No radios in the fallback services, so no Wi-Fi page; the clock is
    // not synchronised, so the clock page.
    expect(find.byKey(const ValueKey('first-run-clock')), findsOneWidget);
    await choose(tester, 5); // Set the clock
    expect(requests.any((r) => r['op'] == 'clock' && r['set'] != null), isTrue);
    expect(find.byKey(const ValueKey('first-run-device-name')), findsOneWidget);
    await choose(tester, 0);
    expect(find.byKey(const ValueKey('keyboard-text')), findsOneWidget);
    await type(tester, ''); // keeps the initial name
    expect(find.byKey(const ValueKey('first-run-account')), findsOneWidget);
    await choose(tester, 0);
    await type(tester, 'al');
    await choose(tester, 1);
    await type(tester, 'x');
    await type(tester, 'x');
    await choose(tester, 2);
    expect(find.byKey(const ValueKey('first-run-mode')), findsOneWidget);
    // The page opens on the theme in use, dark, the last row; light is
    // the row above it.
    await choose(tester, -1);
    expect(settings.value('/settings/appearance/mode'), 'light');
    expect(find.byKey(const ValueKey('first-run-scale')), findsOneWidget);
    await choose(tester, 0);
    expect(find.byKey(const ValueKey('first-run-finish')), findsOneWidget);
    await choose(tester, 0);
    final pending = requests.firstWhere(
      (r) => r['op'] == 'first-run' && r['pending'] != null,
    );
    expect(pending['pending'], {
      'timezone': 'UTC',
      'hostname': 'tempo',
      'username': 'al',
      'password': 'x',
    });
    expect(requests.last['op'], 'reboot');
    expect(finished, isTrue);
  });

  testWidgets('what a flasher already settled is not asked again', (
    tester,
  ) async {
    Future<Map<String, Object?>> settled(Map<String, Object?> request) async {
      requests.add(request);
      return switch (request['op']) {
        'first-run' when request['pending'] == null => {
          'ok': true,
          'done': false,
          'applied': {
            'username': 'alice',
            'password': true,
            'hostname': 'alices-player',
            'timezone': 'Europe/Berlin',
            'locale': 'de_DE.UTF-8',
          },
        },
        'clock' => {'ok': true, 'synchronized': true, 'ntp': true, 'now': ''},
        _ => {'ok': true},
      };
    }

    await tester.pumpWidget(
      FirstRunApp(
        services: PlayerServices.fallback,
        state: FirstRunState(request: settled),
        settings: settings,
        wheel: wheel,
        onFinished: () => finished = true,
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester, 0); // welcome
    expect(
      find.byKey(const ValueKey('first-run-mode')),
      findsOneWidget,
      reason: 'language, zone, clock, name and account were settled already',
    );
    await choose(tester, 0);
    await choose(tester, 0);
    expect(find.byKey(const ValueKey('first-run-finish')), findsOneWidget);
    await choose(tester, 0);
    expect(
      requests.where((r) => r['op'] == 'first-run' && r['pending'] != null),
      isEmpty,
    );
    expect(requests.last['op'], 'reboot');
    expect(finished, isTrue);
  });
}
