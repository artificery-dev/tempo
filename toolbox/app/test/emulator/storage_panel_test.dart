import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

class PanelStorage extends ValueNotifier<DataStorageStatus>
    implements DataStorageController, RetryableDataStorage {
  PanelStorage(super.value, {this.fail = false});
  final bool fail;
  @override
  Future<void> Function()? beforeChange;
  @override
  Future<void> setPolicy(
    DataStoragePolicy policy, {
    bool replaceExisting = false,
    bool adoptExisting = false,
  }) async {
    if (fail) {
      throw StateError('Card is read-only. Your device profile is unchanged.');
    }
  }

  @override
  Future<void> retryPending() async {}
  @override
  Future<void> adoptCardForStartup() async {}
  @override
  void skipStartup() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json');
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    final flutter = packages.firstWhere((p) => p['name'] == 'flutter') as Map;
    final packageRoot = config.absolute.uri.resolve(
      flutter['rootUri'] as String,
    );
    final root = Uri.parse(
      '${packageRoot.toString().replaceFirst(RegExp(r"/+$"), "")}/',
    );
    final bytes = File.fromUri(
      root.resolve(
        '../../bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      ),
    ).readAsBytesSync();
    await (FontLoader(
      'PanelRoboto',
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  });
  final base = UiScale.regular.typography;
  final theme = UiScale.regular
      .theme(Brightness.dark)
      .copyWith(
        typography: base.copyWith(
          title: base.title.copyWith(fontFamily: 'PanelRoboto'),
          body: base.body.copyWith(fontFamily: 'PanelRoboto'),
          label: base.label.copyWith(fontFamily: 'PanelRoboto'),
          caption: base.caption.copyWith(fontFamily: 'PanelRoboto'),
          bodySmall: base.bodySmall.copyWith(fontFamily: 'PanelRoboto'),
        ),
      );
  // 480x360 is the smallest screen Tempo supports.
  for (final pixels in [Panel.pixels]) {
    for (final scenario in [
      'startup',
      'picker',
      'collision',
      'error',
      'recovery',
    ]) {
      testWidgets(
        '${pixels.width.toInt()}x${pixels.height.toInt()} $scenario keeps wheel actions visible at constrained panel size',
        (tester) async {
          tester.view.physicalSize = pixels;
          tester.view.devicePixelRatio = Panel.devicePixelRatio;
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          final wheel = ClickWheelController();
          final storage = PanelStorage(
            DataStorageStatus(
              cardPresent: scenario != 'recovery',
              cardProfileExists: scenario != 'error',
              available: scenario != 'recovery',
              usingCard: scenario == 'recovery',
              restarting: scenario == 'recovery',
              deviceProfileExists: true,
              error: scenario == 'recovery'
                  ? 'The selected SD card is unavailable. Insert the original card or choose a saved device profile. Previous profile data has been preserved.'
                  : null,
            ),
            fail: scenario == 'error',
          );
          final choices = DataStorageChoices(controller: storage);
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: TomeApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                builder: (context, child) =>
                    ClickWheelInput(controller: wheel, child: child!),
                home: scenario == 'startup'
                    ? Padding(
                        padding: EdgeInsets.all(
                          theme.widgets.dialog.resolve().margin,
                        ),
                        child: Center(
                          child: DataStoragePrompt(controller: storage),
                        ),
                      )
                    : Padding(
                        padding: EdgeInsets.only(
                          top: scenario == 'recovery'
                              ? 0
                              : chromeScale.barHeight,
                        ),
                        child: choices,
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (scenario == 'collision') {
            // External is the second option; choosing it over a card that
            // already holds a library raises the collision choice.
            wheel.jog(1);
            await tester.pumpAndSettle();
          }
          if (scenario == 'collision' || scenario == 'error') {
            wheel.press(WheelButton.select);
            await tester.pumpAndSettle();
          }
          Future<void> capture(String suffix) async {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage(
                pixelRatio: Panel.devicePixelRatio,
              );
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              image.dispose();
              final out = Directory('../../build/validation/storage-panel')
                ..createSync(recursive: true);
              File(
                '${out.path}/${pixels.width.toInt()}x${pixels.height.toInt()}-$scenario-$suffix.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
            });
          }

          await capture('initial');
          if (scenario == 'collision') {
            final warning = tester.getRect(
              find.text('Use existing keeps that profile.'),
            );
            expect(
              warning.bottom,
              lessThanOrEqualTo(tester.getRect(find.text('Use existing')).top),
            );
          }

          expect(tester.takeException(), isNull);
          final labels = switch (scenario) {
            'collision' => ['Use existing', 'Move current data', 'Cancel'],
            'startup' => ['Use card', 'Use device'],
            'recovery' => ['Retry move'],
            _ => ['Internal', 'External'],
          };
          for (var i = 0; i < labels.length; i++) {
            if (i > 0) {
              wheel.jog(1);
              await tester.pumpAndSettle();
            }
            final label = labels[i];
            final text = find.text(label);
            expect(text, findsOneWidget);
            final bounds = tester.getRect(text);
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(
              bounds.right,
              lessThanOrEqualTo((pixels / Panel.devicePixelRatio).width),
            );
            expect(bounds.top, greaterThanOrEqualTo(0));
            expect(
              bounds.bottom,
              lessThanOrEqualTo((pixels / Panel.devicePixelRatio).height),
            );
            await capture('choice-$i');
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox());
          storage.dispose();
        },
      );
    }
  }
}
