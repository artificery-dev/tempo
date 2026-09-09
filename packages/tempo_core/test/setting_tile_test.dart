import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// A settings row carries its control rather than hiding it behind a page:
/// a switch at the trailing end of the title's line, a slider on a line of
/// its own under it, and the description under that. The heights are
/// declared rather than measured, because the list has to know every row's
/// height before it builds one.
void main() {
  Widget harness(Widget child, {UiScale scale = UiScale.regular}) => TomeApp(
    debugShowCheckedModeBanner: false,
    theme: scale.theme(Brightness.dark),
    home: UiScaleScope(
      scale: scale,
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: 175, child: child),
      ),
    ),
  );

  group('SettingTile', () {
    testWidgets('all scales use symmetric padding and one internal gap', (
      tester,
    ) async {
      for (final scale in UiScale.values) {
        for (final hasSummary in [false, true]) {
          for (final hasBody in [false, true]) {
            await tester.pumpWidget(
              harness(
                SettingTile(
                  title: 'Title',
                  summary: hasSummary ? 'Description' : null,
                  body: hasBody
                      ? const ColoredBox(
                          key: Key('control'),
                          color: Color(0xff555555),
                        )
                      : null,
                ),
                scale: scale,
              ),
            );
            final tile = tester.getRect(find.byType(SettingTile));
            final title = tester.getRect(find.text('Title'));
            expect(title.left - tile.left, closeTo(scale.space.x4, 0.01));
            expect(
              tile.height,
              closeTo(
                SettingTile.extentOf(scale, summary: hasSummary, body: hasBody),
                0.01,
              ),
            );
            final words = tester.getRect(
              find.descendant(
                of: find.byType(SettingTile),
                matching: find.byType(Column),
              ),
            );
            expect(words.top - tile.top, closeTo(scale.space.x4, 0.01));
            expect(tile.bottom - words.bottom, closeTo(scale.space.x4, 0.01));
            if (hasBody) {
              final control = tester.getRect(find.byKey(const Key('control')));
              expect(tile.right - control.right, closeTo(scale.space.x4, 0.01));
              if (hasSummary) {
                final summary = tester.getRect(find.byType(MarqueeText));
                expect(
                  summary.top - control.bottom,
                  closeTo(scale.space.x3 / 2, 0.01),
                );
              }
            }
            expect(tester.takeException(), isNull);
          }
        }
      }
    });

    testWidgets(
      'icons and controls share the header; lower lines span the tile',
      (tester) async {
        for (final scale in UiScale.values) {
          for (final hasBody in [false, true]) {
            await tester.pumpWidget(
              harness(
                SettingTile(
                  title: 'Title',
                  icon: LucideIcons.paintbrush,
                  trailing: const SizedBox(
                    key: Key('trailing'),
                    width: 12,
                    height: 8,
                  ),
                  summary: 'Description',
                  body: hasBody
                      ? const ColoredBox(
                          key: Key('body'),
                          color: Color(0xff555555),
                        )
                      : null,
                ),
                scale: scale,
              ),
            );
            final tile = tester.getRect(find.byType(SettingTile));
            final title = tester.getRect(find.text('Title'));
            final icon = tester.getRect(find.byIcon(LucideIcons.paintbrush));
            final trailing = tester.getRect(find.byKey(const Key('trailing')));
            final summary = tester.getRect(find.byType(MarqueeText));
            expect(icon.center.dy, closeTo(title.center.dy, 0.01));
            expect(trailing.center.dy, closeTo(title.center.dy, 0.01));
            expect(summary.left, closeTo(tile.left + scale.space.x4, 0.01));
            expect(summary.right, closeTo(tile.right - scale.space.x4, 0.01));
            if (hasBody) {
              final body = tester.getRect(find.byKey(const Key('body')));
              expect(body.left, summary.left);
              expect(body.right, summary.right);
              expect(body.top, greaterThan(title.bottom));
              expect(summary.top, greaterThan(body.bottom));
            }
            expect(tester.takeException(), isNull);
          }
        }
      },
    );

    testWidgets('the tile draws the height it declares', (tester) async {
      await tester.pumpWidget(
        harness(
          const SettingTile(
            title: 'Theme',
            summary:
                'Light, dark, or the '
                'machine',
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SettingTile)).height,
        closeTo(SettingTile.extentOf(UiScale.regular, summary: true), 0.01),
      );
    });

    testWidgets('the description is one line, ellipsized: a tile that grew '
        'to fit its words would break the list\'s rhythm', (tester) async {
      await tester.pumpWidget(
        harness(
          const SettingTile(
            title: 'Sleep After',
            summary:
                'A very long description indeed, one that could not '
                'possibly sit on a single line of a panel this narrow, and '
                'so must be cut off rather than wrap.',
          ),
        ),
      );
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Text),
        ),
      );
      expect(text.maxLines, 1);
      expect(
        text.overflow,
        TextOverflow.ellipsis,
        reason: 'a row the wheel is not on says what fits and stops',
      );
      expect(
        tester.getSize(find.byType(SettingTile)).height,
        closeTo(SettingTile.extentOf(UiScale.regular, summary: true), 0.01),
      );
    });

    testWidgets('a disabled tile is still there, and still says what it '
        'does', (tester) async {
      await tester.pumpWidget(
        harness(
          const SettingTile(
            title: 'Dim Level',
            summary: 'A fraction of the brightness',
            enabled: false,
          ),
        ),
      );
      expect(find.text('Dim Level'), findsOneWidget);
      expect(find.text('A fraction of the brightness'), findsOneWidget);
      final faded = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byType(SettingTile),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(faded.opacity, lessThan(1));
    });
  });

  group('SettingSwitchTile', () {
    testWidgets('the switch shares the title line at the trailing end', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          SettingSwitchTile(
            title: 'Gapless',
            summary: 'No silence between two tracks',
            value: true,
            onChanged: (_) {},
          ),
        ),
      );

      final tile = tester.getRect(find.byType(SettingSwitchTile));
      final control = tester.getRect(find.byType(Switch<bool>));
      // The trailing control is centered on the title line.
      expect(
        control.center.dy,
        closeTo(tester.getRect(find.text('Gapless')).center.dy, 0.5),
      );
      // At the trailing end: past the middle of the tile.
      expect(control.left, greaterThan(tile.center.dx));
      // And it still fits inside the row.
      expect(control.height, lessThan(tile.height));
    });

    testWidgets('it is as tall as a tile with a description and no body', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          SettingSwitchTile(
            title: 'Gapless',
            summary: 'No silence between two tracks',
            value: false,
            onChanged: (_) {},
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SettingSwitchTile)).height,
        closeTo(
          SettingSwitchTile.extentOf(UiScale.regular, summary: true),
          0.01,
        ),
      );
    });

    testWidgets('a pointer on the switch throws it - the emulator and a '
        'desk have one', (tester) async {
      bool? moved;
      await tester.pumpWidget(
        harness(
          SettingSwitchTile(
            title: 'Gapless',
            value: false,
            onChanged: (value) => moved = value,
          ),
        ),
      );
      await tester.tap(find.byType(Switch<bool>));
      expect(moved, isTrue);
    });

    testWidgets('a disabled switch does not move', (tester) async {
      var moved = false;
      await tester.pumpWidget(
        harness(
          SettingSwitchTile(
            title: 'Crossfade',
            value: false,
            enabled: false,
            onChanged: (_) => moved = true,
          ),
        ),
      );
      await tester.tap(find.byType(Switch<bool>), warnIfMissed: false);
      expect(moved, isFalse);
    });
  });

  group('SettingSliderTile', () {
    Widget slider({bool captured = false, ValueChanged<double>? onChanged}) =>
        SettingSliderTile(
          title: 'Brightness',
          summary: 'How much light the panel gives',
          value: 80,
          min: 10,
          max: 100,
          step: 5,
          unit: '%',
          captured: captured,
          onChanged: onChanged ?? (_) {},
        );

    testWidgets('the track sits under the title and over the description', (
      tester,
    ) async {
      await tester.pumpWidget(harness(slider()));
      final title = tester.getRect(find.text('Brightness'));
      final track = tester.getRect(find.byType(Slider));
      final summary = tester.getRect(
        find.text('How much light the panel gives'),
      );
      expect(track.top, greaterThanOrEqualTo(title.bottom - 0.5));
      expect(summary.top, greaterThanOrEqualTo(track.bottom - 0.5));
    });

    testWidgets('the track spans the words, and the reading stands at the '
        'trailing edge on the title line', (tester) async {
      await tester.pumpWidget(harness(slider()));
      final tile = tester.getRect(find.byType(SettingSliderTile));
      final track = tester.getRect(find.byType(Slider));
      final title = tester.getRect(find.text('Brightness'));

      // The track is the words' column, from the title's edge across.
      expect(track.left, closeTo(title.left, 0.5));
      expect(track.width, greaterThan(tile.width * 0.7));

      final reading = tester.getRect(find.text('80%'));
      expect(reading.center.dy, closeTo(title.center.dy, 1));
      expect(reading.right, closeTo(track.right, 0.01));
    });

    testWidgets('it is a row, a description and a control line tall', (
      tester,
    ) async {
      await tester.pumpWidget(harness(slider()));
      expect(
        tester.getSize(find.byType(SettingSliderTile)).height,
        closeTo(
          SettingSliderTile.extentOf(UiScale.regular, summary: true),
          0.01,
        ),
      );
    });

    testWidgets('the step divides the track: a detent lands on a stop', (
      tester,
    ) async {
      await tester.pumpWidget(harness(slider()));
      // 10..100 by 5 is eighteen stops.
      expect(tester.widget<Slider>(find.byType(Slider)).divisions, 18);
    });

    testWidgets('holding the wheel grows the thumb and lights the reading', (
      tester,
    ) async {
      await tester.pumpWidget(harness(slider()));
      final resting = tester.widget<Slider>(find.byType(Slider)).style!;

      await tester.pumpWidget(harness(slider(captured: true)));
      final held = tester.widget<Slider>(find.byType(Slider)).style!;

      expect(held.thumbSize, greaterThan(resting.thumbSize));
      expect(
        held.trackHeight,
        resting.trackHeight,
        reason:
            'the line is the '
            'same line; only the grip says who has it',
      );
    });
  });

  group('in a list', () {
    testWidgets('a switch tile and a slider tile sit in one WheelList, each '
        'its own height', (tester) async {
      const scale = UiScale.regular;
      final tiles = <Widget>[
        SettingSwitchTile(
          title: 'Gapless',
          summary: 'No silence between two tracks',
          value: true,
          onChanged: (_) {},
        ),
        SettingSliderTile(
          title: 'Brightness',
          summary: 'How much light the panel gives',
          value: 80,
          min: 10,
          max: 100,
          step: 5,
          unit: '%',
          onChanged: (_) {},
        ),
        const SettingTile(title: 'About'),
      ];
      final extents = <double>[
        SettingSwitchTile.extentOf(scale, summary: true),
        SettingSliderTile.extentOf(scale, summary: true),
        SettingTile.extentOf(scale),
      ];

      await tester.pumpWidget(
        harness(
          SizedBox(
            height: 300,
            child: WheelList(
              itemExtent: scale.rowExtent,
              extentOf: (index) => extents[index],
              autofocus: true,
              children: tiles,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(SettingSwitchTile)).height,
        closeTo(extents[0], 0.01),
      );
      expect(
        tester.getSize(find.byType(SettingSliderTile)).height,
        closeTo(extents[1], 0.01),
      );
      // The rows stack without overlapping or gapping.
      final first = tester.getRect(find.byType(SettingSwitchTile));
      final second = tester.getRect(find.byType(SettingSliderTile));
      expect(second.top, closeTo(first.bottom, 0.01));
    });
  });

  group('SettingChoiceTile', () {
    const short = <SettingOption>[
      SettingOption(value: 'system', label: 'System'),
      SettingOption(value: 'light', label: 'Light'),
      SettingOption(value: 'dark', label: 'Dark'),
    ];
    const long = <SettingOption>[
      SettingOption(value: 'wakes', label: 'During Background Wakes'),
      SettingOption(value: 'always', label: 'Always'),
      SettingOption(value: 'never', label: 'Never'),
    ];

    testWidgets('two or three short answers ride the tile', (tester) async {
      await tester.pumpWidget(
        harness(
          SettingChoiceTile(
            title: 'Theme',
            summary: 'Light, dark, or the machine',
            value: 'dark',
            options: short,
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byType(WheelRail<Object?>), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      expect(
        tester.getSize(find.byType(SettingChoiceTile)).height,
        closeTo(
          SettingChoiceTile.extentOf(
            UiScale.regular,
            inline: true,
            summary: true,
          ),
          0.01,
        ),
      );
    });

    testWidgets('answers too wordy for a segment get a page instead', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          SettingChoiceTile(
            title: 'Wi-Fi in Standby',
            value: 'wakes',
            options: long,
            onOpen: () {},
          ),
        ),
      );
      expect(find.byType(WheelRail<Object?>), findsNothing);
      // The answer and the way in.
      expect(find.text('During Background Wakes'), findsOneWidget);
      expect(
        tester.getSize(find.byType(SettingChoiceTile)).height,
        closeTo(
          SettingChoiceTile.extentOf(UiScale.regular, inline: false),
          0.01,
        ),
      );
    });

    testWidgets('an item can say page even where the answers would fit - a '
        'list that will grow belongs on a page from the start', (tester) async {
      await tester.pumpWidget(
        harness(
          SettingChoiceTile(
            title: 'Network',
            value: 'home',
            layout: SettingLayout.page,
            options: const [
              SettingOption(value: 'home', label: 'Home'),
              SettingOption(value: 'cafe', label: 'Cafe'),
            ],
            onOpen: () {},
          ),
        ),
      );
      expect(find.byType(WheelRail<Object?>), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('and can say inline even where they would not fit', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          SettingChoiceTile(
            title: 'Wi-Fi in Standby',
            value: 'never',
            layout: SettingLayout.inline,
            options: long,
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byType(WheelRail<Object?>), findsOneWidget);
    });

    testWidgets('a stored answer that is no longer offered reads as none, '
        'not as the first', (tester) async {
      await tester.pumpWidget(
        harness(
          SettingChoiceTile(
            title: 'Network',
            value: 'a-network-out-of-range',
            options: long,
            onOpen: () {},
          ),
        ),
      );
      expect(find.text('-'), findsOneWidget);
    });

    testWidgets('the track is the wheel\'s, not a pointer\'s: a settings '
        'row is walked, never tapped', (tester) async {
      Object? chosen;
      await tester.pumpWidget(
        harness(
          SettingChoiceTile(
            title: 'Theme',
            value: 'dark',
            options: short,
            onChanged: (value) => chosen = value,
          ),
        ),
      );
      await tester.tap(find.text('Light'), warnIfMissed: false);
      expect(chosen, isNull);

      // It is driven by whoever has given the row the wheel.
      final rail = WheelRailController();
      await tester.pumpWidget(
        harness(
          SettingChoiceTile(
            title: 'Theme',
            value: 'dark',
            options: short,
            controller: rail,
            captured: true,
            onChanged: (value) => chosen = value,
          ),
        ),
      );
      rail.step(-1);
      await tester.pumpAndSettle();
      expect(chosen, 'light');
    });
  });

  group('SettingStepperTile', () {
    testWidgets('the number shares the title line and costs no height', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          SettingStepperTile(
            title: 'Volume Step',
            summary: 'How much one detent moves it',
            value: 5,
            min: 1,
            max: 10,
            unit: '%',
            onChanged: (_) {},
          ),
        ),
      );
      final tile = tester.getRect(find.byType(SettingStepperTile));
      final reading = tester.getRect(find.text('5%'));
      expect(
        reading.center.dy,
        closeTo(tester.getRect(find.text('Volume Step')).center.dy, 1),
      );
      expect(reading.left, greaterThan(tile.center.dx));
      expect(
        tile.height,
        closeTo(
          SettingStepperTile.extentOf(UiScale.regular, summary: true),
          0.01,
        ),
      );
    });

    testWidgets('the arrows show only while the wheel is on it', (
      tester,
    ) async {
      Widget stepper({required bool captured}) => harness(
        SettingStepperTile(
          title: 'Seek Step',
          value: 10,
          min: 5,
          max: 60,
          step: 5,
          unit: 's',
          captured: captured,
          onChanged: (_) {},
        ),
      );

      await tester.pumpWidget(stepper(captured: false));
      expect(find.byType(Icon), findsNothing);

      await tester.pumpWidget(stepper(captured: true));
      expect(find.byType(Icon), findsNWidgets(2));
    });

    testWidgets('a detent steps by the step, and stops at the ends', (
      tester,
    ) async {
      const tile = SettingStepperTile(
        title: 'Seek Step',
        value: 10,
        min: 5,
        max: 60,
        step: 5,
      );
      expect(tile.stepped(1), 15);
      expect(tile.stepped(-1), 5);
      expect(tile.stepped(-4), 5, reason: 'clamped at the bottom');
      expect(tile.stepped(100), 60, reason: 'and at the top');
    });
  });

  group('the plain tiles', () {
    testWidgets('a page tile says what it is set to, and shows the way in', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          const SettingPageTile(
            title: 'Quick Settings',
            reading: 'Select + Power',
            summary: 'The pinned settings',
          ),
        ),
      );
      expect(find.text('Select + Power'), findsOneWidget);
      expect(find.byType(Icon), findsOneWidget);
    });

    testWidgets('an info tile is a reading and no way in', (tester) async {
      await tester.pumpWidget(
        harness(
          const SettingInfoTile(title: 'Battery', reading: '78%, charging'),
        ),
      );
      expect(find.text('78%, charging'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('a dangerous action wears a mark; a plain one does not', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(const SettingActionTile(title: 'Update Library')),
      );
      expect(find.byType(Icon), findsNothing);

      await tester.pumpWidget(
        harness(
          const SettingActionTile(title: 'Erase Everything', danger: true),
        ),
      );
      expect(find.byType(Icon), findsOneWidget);
    });

    testWidgets('an action that is running reports on its own row', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          const SettingActionTile(
            title: 'Update Library',
            busy: 'Scanning 412',
          ),
        ),
      );
      expect(find.text('Scanning 412'), findsOneWidget);
    });
  });

  group('taking the wheel', () {
    /// Two settings in a list, the way a settings screen holds them: the
    /// list drives until a row is activated, and then that row's control
    /// does, until it lets go. This is the pattern a real settings screen
    /// will use, spelled out here because it is the interaction and not
    /// the widget that is worth pinning.
    testWidgets('a slider tile moves on the jog while it has the wheel, and '
        'the list moves again when it lets go', (tester) async {
      const scale = UiScale.regular;
      final wheel = ClickWheelController();
      var brightness = 80.0;
      int? captured;
      var gapless = true;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            final tiles = <Widget>[
              InputCapture(
                active: captured == 0,
                captures: const {WheelInput.wheel},
                onCapture: (intent) {
                  if (intent case JogIntent(:final amount)) {
                    setState(() {
                      brightness = (brightness + amount * 5).clamp(10, 100);
                    });
                  }
                },
                onRelease: (_) => setState(() => captured = null),
                child: SettingSliderTile(
                  title: 'Brightness',
                  value: brightness,
                  min: 10,
                  max: 100,
                  step: 5,
                  unit: '%',
                  captured: captured == 0,
                ),
              ),
              SettingSwitchTile(
                title: 'Gapless',
                value: gapless,
                onChanged: (value) => setState(() => gapless = value),
              ),
            ];

            return TomeApp(
              debugShowCheckedModeBanner: false,
              theme: scale.theme(Brightness.dark),
              builder: (context, child) =>
                  ClickWheelInput(controller: wheel, child: child!),
              home: UiScaleScope(
                scale: scale,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: 175,
                    height: 120,
                    child: WheelList(
                      itemExtent: scale.rowExtent,
                      extentOf: (index) => index == 0
                          ? SettingSliderTile.extentOf(scale)
                          : SettingSwitchTile.extentOf(scale),
                      autofocus: true,
                      onActivate: (index) => setState(() {
                        // The slider takes the wheel; the switch is thrown
                        // where it stands.
                        if (index == 0) {
                          captured = 0;
                        } else {
                          gapless = !gapless;
                        }
                      }),
                      children: tiles,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      // The list is driving: a jog walks to the switch and back.
      wheel.jog(1);
      await tester.pumpAndSettle();
      expect(brightness, 80, reason: 'the slider did not move');
      wheel.jog(-1);
      await tester.pumpAndSettle();

      // Activate the slider: now the wheel is its own.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.text('80%'), findsOneWidget);

      wheel.jog(2);
      await tester.pumpAndSettle();
      expect(brightness, 90, reason: 'two detents of five, on the slider');
      expect(find.text('90%'), findsOneWidget);

      // And the switch was never touched on the way: the jog never reached
      // the list at all.
      expect(gapless, isTrue);

      // The center gives it back, and the list drives again.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(1);
      await tester.pumpAndSettle();
      expect(brightness, 90, reason: 'the slider is done moving');

      // The wheel is on the switch now, and the center throws it.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(gapless, isFalse);
    });
  });
}
