import 'dart:convert';
import 'dart:async';
import 'package:file/local.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/main.dart';
import 'package:tempo_toolbox/toolbox_controller.dart';
import 'package:tomeui/tomeui.dart';
import 'toolbox_controller_test.dart' show FakeUsbEngine;

class WalkthroughEngine extends FakeUsbEngine {
  @override
  Future<Map<String, dynamic>> prepareFirmware() async {
    final result = await super.prepareFirmware();
    (result['firmware'] as Map)['icon'] =
        'data:image/png;base64,${base64Encode(const LocalFileSystem().file('../../assets/tempo/web/icon-192.png').readAsBytesSync())}';
    return result;
  }

  @override
  Future<Map<String, dynamic>> prepareBackup({bool resume = false}) async => {
    'ready': true,
    'filename': 'player.img.gz',
  };
}

class DelayedFirmwareEngine extends WalkthroughEngine {
  final validation = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> prepareFirmware() async {
    final info = await super.prepareFirmware();
    onEvent({'event': 'firmware-info', ...info});
    onEvent({
      'event': 'firmware-prepare-progress',
      'completed': 123,
      'total': 1000,
    });
    return validation.future;
  }
}

class DiagnosticEngine extends WalkthroughEngine {
  final pending = Completer<Map<String, dynamic>>();
  final stoppingDone = Completer<void>();
  int reads = 0, stops = 0;
  @override
  Future<Map<String, dynamic>> partitions() {
    reads++;
    return pending.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    await stoppingDone.future;
    if (!pending.isCompleted) {
      pending.complete({'event': 'cancelled', 'message': 'Operation stopped.'});
    }
  }
}

void main() {
  testWidgets('diagnostics launches separately and can stop waiting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = DiagnosticEngine();
    final model = ToolboxController(engine: engine);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [toolboxControllerProvider.overrideWith((ref) => model)],
        child: const InstallerApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read-only diagnostics'));
    await tester.pumpAndSettle();
    expect(engine.reads, 0);
    expect(find.text('What would you like to do?'), findsNothing);
    await tester.tap(find.text('Connect and read partition map'));
    await tester.pumpAndSettle();
    expect(engine.reads, 1);
    expect(model.busy, isTrue);
    final stop = find.byKey(const ValueKey('diagnostics-stop'));
    await tester.tap(stop);
    await tester.pump();
    expect(engine.stops, 1);
    expect(tester.widget<Button>(stop).onPressed, isNull);
    expect(model.busy, isTrue);
    engine.stoppingDone.complete();
    await tester.pumpAndSettle();
    expect(model.busy, isFalse);
    expect(find.text('Operation stopped.'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('What would you like to do?'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'centered chooser shows metadata while validation blocks Continue',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = DelayedFirmwareEngine();
      final model = ToolboxController(engine: engine);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [toolboxControllerProvider.overrideWith((ref) => model)],
          child: const InstallerApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-backup')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('operation-Flash')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workflow-next')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('firmware-chooser'));
      expect(tester.getSize(card).width, 480);
      expect(
        tester
            .widget<Button>(find.widgetWithText(Button, 'Choose package'))
            .variant,
        SurfaceVariant.subtle,
      );
      await tester.tap(find.text('Choose package'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Version test'), findsOneWidget);
      expect(find.text('12.3%'), findsOneWidget);
      final previewImage = find.descendant(
        of: card,
        matching: find.byType(Image),
      );
      final provider = tester.widget<Image>(previewImage).image;
      for (final completed in [200, 300, 450]) {
        model.event({
          'event': 'firmware-prepare-progress',
          'completed': completed,
          'total': 1000,
        });
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<Image>(previewImage).image, provider);
      }
      expect(find.text('Validating package '), findsOneWidget);
      final next = find.byKey(const ValueKey('workflow-next'));
      expect(find.descendant(of: card, matching: next), findsNothing);
      final back = find.byKey(const ValueKey('workflow-back'));
      expect(
        tester.getBottomLeft(back).dy,
        lessThan(tester.getTopLeft(card).dy),
      );
      final viewport = find.byKey(const ValueKey('toolbox-page-scroll'));
      expect(
        tester.getBottomLeft(viewport).dy - tester.getBottomLeft(next).dy,
        closeTo(28, 1),
      );

      expect(
        tester.getTopLeft(next).dy,
        greaterThan(tester.getBottomLeft(card).dy),
      );
      expect(tester.widget<Button>(next).onPressed, isNull);
      expect(
        tester
            .widget<Button>(
              find.widgetWithText(Button, 'Choose a different package'),
            )
            .variant,
        SurfaceVariant.ghost,
      );
      engine.validation.complete({
        'ready': true,
        'firmware': {'name': 'Tempo', 'version': 'test'},
      });
      await tester.pumpAndSettle();
      expect(tester.widget<Button>(next).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('backup walks through selection, review, transfer and result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = WalkthroughEngine();
    final model = ToolboxController(engine: engine);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [toolboxControllerProvider.overrideWith((ref) => model)],
        child: const InstallerApp(),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> tap(Finder finder) async {
      await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    final next = find.byKey(const ValueKey('workflow-next'));
    await tap(find.byKey(const ValueKey('nav-backup')));
    await tap(next);
    expect(tester.widget<Button>(next).onPressed, isNull);
    await tap(find.text('Choose backup destination'));
    await tap(next);
    expect(find.text('Options'), findsNWidgets(2));
    expect(find.text('Review backup'), findsNothing);
    await tap(next);
    expect(find.text('Review backup'), findsOneWidget);
    expect(find.text('Tempo Recovery'), findsOneWidget);
    expect(engine.connections, 0);
    await tap(next);
    await tap(find.text('Connect and back up'));
    expect(engine.connections, 1);
    expect(model.busy, isTrue);
    model.event({'event': 'error', 'message': 'Device disconnected'});
    await tester.pumpAndSettle();
    expect(find.text('Operation failed'), findsOneWidget);
    await tap(find.text('Start another operation'));
    expect(find.text('What would you like to do?'), findsOneWidget);
    expect(find.text('Choose backup destination'), findsNothing);
    expect(model.backupReady, isFalse);
    expect(model.firmwareReady, isFalse);
    await tap(find.byKey(const ValueKey('operation-Restore')));
    await tap(next);
    expect(find.text('Choose backup'), findsOneWidget);
    final restoreCard = find.byKey(const ValueKey('restore-chooser'));
    expect(tester.getSize(restoreCard).width, 480);
    expect(find.descendant(of: restoreCard, matching: next), findsNothing);
    await tap(find.text('Choose backup'));
    await tap(next);
    expect(find.text('Write options'), findsNothing);
    await tap(next);
    expect(find.text('Review restore'), findsOneWidget);
    await tap(find.text('Back'));
    await tap(find.text('Back'));
    await tap(find.text('Back'));
    await tap(find.byKey(const ValueKey('operation-Flash')));
    await tap(next);
    expect(find.text('Choose package'), findsOneWidget);
    expect(tester.widget<Button>(next).onPressed, isNull);
    await tap(find.text('Choose package'));
    expect(find.text('Version test'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('firmware-identity')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    await tap(next);
    expect(find.text('Options'), findsNWidgets(2));
    expect(find.text('Review flash'), findsNothing);
    expect(model.verifyWrites, isTrue);
    await tap(find.byKey(const ValueKey('verify-written-data')));
    expect(model.verifyWrites, isFalse);
    // First-run choices sit in their own collapsed section above Advanced.
    expect(find.text('Device Setup'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-setup-hostname')), findsNothing);
    await tap(find.byKey(const ValueKey('device-setup')));
    await tester.enterText(
      find.byKey(const ValueKey('device-setup-hostname')),
      '-y2',
    );
    await tester.pumpAndSettle();
    expect(model.deviceSetup.hostname, '-y2');
    expect(find.textContaining('starting with a letter'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('device-setup-hostname')),
      'my-y2',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('starting with a letter'), findsNothing);
    await tap(find.byKey(const ValueKey('device-setup')));
    expect(find.byKey(const ValueKey('device-setup-hostname')), findsNothing);
    expect(model.deviceSetup.hostname, 'my-y2');
    tester.view.physicalSize = const Size(320, 900);
    await tester.pumpAndSettle();
    await tap(find.text('Advanced'));
    expect(find.text('Connection files'), findsOneWidget);
    expect(find.text('Read-only diagnostics'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Skip matching data'),
      150,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('toolbox-page-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Write options'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tap(find.byKey(const ValueKey('skip-matching-data')));
    expect(model.resumeWrites, isTrue);
    await tap(next);
    expect(find.text('Review flash'), findsOneWidget);
    expect(find.text('Skip matching data'), findsOneWidget);
    expect(find.text('Enabled'), findsNWidgets(3));
    expect(find.text('Device setup'), findsOneWidget);
    expect(find.text('Device name'), findsOneWidget);
    await tap(next);
    expect(find.text('Write options'), findsNothing);
    expect(find.text('Connect and flash'), findsOneWidget);
    expect(find.byType(Progress), findsNothing);
    model.event({
      'event': 'firmware-prepare-progress',
      'completed': 100,
      'total': 100,
      'message': 'Checking input integrity…',
    });
    await tester.pump();
    expect(find.byType(Progress), findsOneWidget);
    expect(
      find.byKey(const ValueKey('firmware-integrity-spinner')),
      findsOneWidget,
    );
    expect(find.text('Checking input integrity…'), findsOneWidget);
    model.event({'event': 'waiting', 'message': 'Waiting for Tempo Recovery…'});
    await tester.pump();
    expect(find.byType(Progress), findsNothing);
    model.event({
      'event': 'recovery-boot-progress',
      'message': 'Downloading Tempo Recovery',
      'completed': 50,
      'total': 100,
    });
    await tester.pump();
    expect(find.byType(Progress), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text('Downloading Tempo Recovery'), findsOneWidget);
    expect(find.text('Overall flash'), findsNothing);
    model.event({
      'event': 'recovery-starting',
      'message': 'Starting Tempo Recovery; waiting for USB…',
    });
    await tester.pump();
    expect(find.byType(Progress), findsOneWidget);
    expect(
      find.text('Starting Tempo Recovery; waiting for USB…'),
      findsOneWidget,
    );
    model.event({'event': 'flash-started', 'completed': 0, 'total': 100});
    await tester.pump();
    expect(find.byType(Progress), findsOneWidget);
    model.event({
      'event': 'flash-progress',
      'phase': 'writing',
      'mapping': 'ANDROID',
      'completed': 50,
      'total': 100,
      'task_completed': 10,
      'task_total': 60,
      'large_partition_count': 2,
      'bytes_per_second': 8.5 * 1048576,
    });
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(Progress), findsNWidgets(2));
    expect(find.text('Overall flash'), findsOneWidget);
    expect(find.text('Writing ANDROID…'), findsOneWidget);
    expect(find.textContaining('8.5 MiB/s'), findsOneWidget);
    model.event({
      'event': 'flash-progress',
      'phase': 'writing',
      'mapping': 'rootfs',
      'completed': 50,
      'total': 100,
      'task_completed': 40,
      'task_total': 90,
      'large_partition_count': 1,
    });
    await tester.pump();
    expect(find.byType(Progress), findsOneWidget);
    expect(find.text('Overall flash'), findsNothing);
    expect(find.text('44.4%'), findsOneWidget);

    model.updateUi(() {
      model.busy = false;
      model.phase = 'firmware-ready';
      model.firmwareReady = true;
      model.backupCompleted = null;
      model.backupTotal = null;
    });
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1200, 1400);
    await tester.pumpAndSettle();
    await tap(find.byKey(const ValueKey('workflow-back')));
    await tap(find.text('Back'));
    await tap(find.text('Back'));
    await tap(find.text('Back'));
    expect(find.text('What would you like to do?'), findsOneWidget);
    await tap(find.byKey(const ValueKey('operation-Restore')));
    await tap(next);
    expect(find.text('Choose backup'), findsOneWidget);
    expect(tester.widget<Button>(next).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
