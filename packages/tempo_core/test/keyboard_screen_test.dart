import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Typing with the wheel: the keys in reading order, the face buttons as
/// arrows, Done handing the text back and Cancel handing back nothing.
void main() {
  late ClickWheelController wheel;
  String? result;
  var asked = false;

  setUp(() {
    wheel = ClickWheelController();
    result = 'untouched';
    asked = false;
  });

  Future<void> pump(
    WidgetTester tester, {
    String initial = '',
    bool obscure = false,
    String? Function(String)? validate,
  }) async {
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            ClickWheelInput(controller: wheel, child: child!),
        home: Navigator(
          onGenerateRoute: (_) => PanelRoute<void>(
            builder: (context) => Builder(
              builder: (context) {
                if (!asked) {
                  asked = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    result = await KeyboardScreen.ask(
                      context,
                      title: 'Name',
                      initial: initial,
                      obscure: obscure,
                      validate: validate,
                    );
                  });
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  int keyIndex(String key) =>
      KeyboardLayout.keys(KeyboardPage.lower).indexOf(key);

  Future<void> jogTo(WidgetTester tester, int from, int to) async {
    wheel.jog(to - from);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester) async {
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
  }

  String shown(WidgetTester tester) => (tester.widget<TitleText>(
    find.byKey(const ValueKey('keyboard-text')),
  )).data;

  testWidgets('the wheel walks the keys and the centre types them', (
    tester,
  ) async {
    await pump(tester, initial: 'ab');
    expect(shown(tester), 'ab');
    var at = 0;
    await jogTo(tester, at, at = keyIndex('c'));
    await press(tester);
    expect(shown(tester), 'abc');
    // The face buttons step: next is one key to the right.
    wheel.press(WheelButton.next);
    await tester.pump();
    await press(tester);
    expect(shown(tester), 'abcv');
    at = keyIndex('v');
    await jogTo(tester, at, at = keyIndex(KeyboardLayout.delete));
    await press(tester);
    expect(shown(tester), 'abc');
    await jogTo(tester, at, at = keyIndex(KeyboardLayout.done));
    await press(tester);
    expect(result, 'abc');
  });

  testWidgets('shift and the symbols page change the keys', (tester) async {
    await pump(tester);
    var at = 0;
    await jogTo(tester, at, at = keyIndex(KeyboardLayout.shift));
    await press(tester);
    expect(find.byKey(const ValueKey('key-Q')), findsOneWidget);
    // Shift lands on the shift key of the upper page; Q is the first key.
    final upper = KeyboardLayout.keys(KeyboardPage.upper);
    await jogTo(tester, upper.indexOf(KeyboardLayout.shift), 0);
    await press(tester);
    expect(shown(tester), 'Q');
    // Symbols, from the upper page's controls.
    await jogTo(tester, 0, upper.indexOf(KeyboardLayout.more));
    await press(tester);
    expect(find.byKey(const ValueKey('key-1')), findsOneWidget);
    final symbols = KeyboardLayout.keys(KeyboardPage.symbols);
    await jogTo(
      tester,
      symbols.indexOf(KeyboardLayout.more),
      symbols.indexOf('1'),
    );
    await press(tester);
    expect(shown(tester), 'Q1');
  });

  testWidgets('a password shows dots, and Done waits for what validate wants', (
    tester,
  ) async {
    await pump(
      tester,
      obscure: true,
      validate: (t) => t.length < 2 ? 'Longer' : null,
    );
    await jogTo(tester, 0, keyIndex('x'));
    await press(tester);
    expect(shown(tester), '•');
    await jogTo(tester, keyIndex('x'), keyIndex(KeyboardLayout.done));
    await press(tester);
    expect(find.byKey(const ValueKey('keyboard-problem')), findsOneWidget);
    expect(result, 'untouched', reason: 'not accepted yet');
    // Back to a letter, then Done again.
    await jogTo(tester, keyIndex(KeyboardLayout.done), keyIndex('y'));
    await press(tester);
    await jogTo(tester, keyIndex('y'), keyIndex(KeyboardLayout.done));
    await press(tester);
    expect(result, 'xy');
  });

  testWidgets('Cancel hands back nothing', (tester) async {
    await pump(tester, initial: 'keep');
    await jogTo(tester, 0, keyIndex(KeyboardLayout.cancel));
    await press(tester);
    expect(result, isNull);
  });
}
