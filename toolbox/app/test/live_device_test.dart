import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_toolbox/live_device_native.dart';
import 'package:toolbox_core/live_device.dart';

class FakeTransport implements DeviceTransport {
  bool fail = false, cancelled = false;
  Completer<String>? pending;
  final calls = <String>[];
  @override
  Future<String> command(List<String> args, {bool root = false}) async {
    calls.add(args.join(' '));
    if (fail) throw DeviceOperationFailure('SSH unavailable');
    if (pending != null) return pending!.future;
    if (args.first == 'systemctl') {
      return ['tempo.service', 'tempod.service', 'tempod-native.service']
          .indexed
          .map(
            (entry) =>
                'Id=${entry.$2}\nActiveState=active\nMainPID=${entry.$1 + 100}',
          )
          .join('\n\n');
    }
    return 'fixture';
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (pending case final value? when !value.isCompleted) {
      value.completeError(DeviceOperationFailure('cancelled'));
    }
  }

  @override
  Future<String> shell(String command, {bool root = false}) =>
      throw UnimplementedError();
  @override
  Future<void> upload(File source, String destination, {bool root = false}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  }) => throw UnimplementedError();
}

class FakeOperations extends LiveDeviceOperations {
  FakeOperations(super.transport);
  final deployments = <Map<String, Object>>[];
  Completer<void>? deployment;
  @override
  Future<void> deployBundle(
    Directory bundle, {
    required bool release,
    required String destination,
    required String flutterPi,
    required String engineDirectory,
    required String pixelFormat,
    required int vmServicePort,
    bool dryRun = false,
    Duration startupWait = const Duration(seconds: 3),
  }) async {
    deployments.add({
      'dryRun': dryRun,
      'release': release,
      'destination': destination,
      'flutterPi': flutterPi,
      'engine': engineDirectory,
      'format': pixelFormat,
      'port': vmServicePort,
    });
    if (!dryRun) await deployment?.future;
  }
}

void main() {
  Future<void> show(WidgetTester tester, LivePlayerPage page) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TomeApp(home: page));
    await tester.pumpAndSettle();
  }

  testWidgets('connection failure is shown and operations can be retried', (
    tester,
  ) async {
    final failed = FakeTransport()..fail = true;
    final good = FakeTransport();
    var count = 0;
    await show(
      tester,
      LivePlayerPage(
        transportFactory: (host, user) {
          expect(host, '10.42.0.1');
          expect(user, 'tempo');
          return count++ == 0 ? failed : good;
        },
      ),
    );
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(find.text('SSH unavailable'), findsOneWidget);
    expect(failed.cancelled, isTrue);
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connected to tempo@'), findsOneWidget);
    expect(good.cancelled, isTrue);
  });
  testWidgets('support report uses shared checks and saves selected output', (
    tester,
  ) async {
    final device = FakeTransport();
    final temp = Directory.systemTemp.createTempSync('live-report-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final output = '${temp.path}/report.json';
    await show(
      tester,
      LivePlayerPage(
        transportFactory: (_, _) => device,
        chooseReport: () async => output,
      ),
    );
    await tester.tap(find.text('Collect support report'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-report')), findsOneWidget);
    expect(device.calls.any((c) => c.startsWith('systemctl show')), isTrue);
    await tester.tap(find.text('Save report'));
    // The page writes a real file as it rebuilds, so pump and give the write
    // real time in turn until the report is actually on disk.
    final saved = File(output);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!saved.existsSync() ||
        !saved.readAsStringSync().contains('player-services')) {
      if (DateTime.now().isAfter(deadline)) fail('the report was never saved');
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pumpAndSettle();
    expect(File(output).readAsStringSync(), contains('player-services'));
  });
  testWidgets(
    'stop cancels diagnostics and keeps navigation disabled until settled',
    (tester) async {
      final device = FakeTransport()..pending = Completer<String>();
      await show(tester, LivePlayerPage(transportFactory: (_, _) => device));
      await tester.tap(find.text('Collect support report'));
      await tester.pump();
      final back = tester.widget<Button>(
        find.ancestor(
          of: find.text('Back to Toolbox'),
          matching: find.byType(Button),
        ),
      );
      expect(back.onPressed, isNull);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(device.cancelled, isTrue);
      expect(find.textContaining('partial report retained'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'deployment requires concrete review then passes production defaults',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('live-bundle-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/app.so').writeAsStringSync('fixture');
      File('${temp.path}/AssetManifest.bin').writeAsStringSync('fixture');
      final device = FakeTransport();
      final operations = FakeOperations(device);
      await show(
        tester,
        LivePlayerPage(
          transportFactory: (_, _) => device,
          chooseBundle: () async => temp.path,
          operationsFactory: (_, _) => operations,
        ),
      );
      await tester.tap(find.text('Choose app bundle'));
      await tester.pumpAndSettle();
      expect(operations.deployments.single['dryRun'], isTrue);
      expect(find.textContaining('/opt/tempo/flutter_assets'), findsOneWidget);
      await tester.tap(find.text('Cancel deployment'));
      await tester.pumpAndSettle();
      expect(operations.deployments.length, 1);
      await tester.tap(find.text('Choose app bundle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deploy'));
      await tester.pumpAndSettle();
      expect(operations.deployments.last, {
        'dryRun': false,
        'release': true,
        'destination': '/opt/tempo/flutter_assets',
        'flutterPi': '/usr/local/bin/flutter-pi',
        'engine': '/usr/lib',
        'format': 'RGB565',
        'port': 41200,
      });
      expect(find.textContaining('startup verified'), findsOneWidget);
    },
  );
  testWidgets(
    'deployment stop waits for rollback completion before navigation',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('live-cancel-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/app.so').writeAsStringSync('fixture');
      File('${temp.path}/AssetManifest.bin').writeAsStringSync('fixture');
      final device = FakeTransport();
      final operations = FakeOperations(device)..deployment = Completer<void>();
      await show(
        tester,
        LivePlayerPage(
          transportFactory: (_, _) => device,
          chooseBundle: () async => temp.path,
          operationsFactory: (_, _) => operations,
        ),
      );
      await tester.tap(find.text('Choose app bundle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deploy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop'));
      await tester.pump();
      expect(device.cancelled, isTrue);
      expect(
        find.text('Cancelling; restoring the previous app if needed…'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Button>(
              find.ancestor(
                of: find.text('Back to Toolbox'),
                matching: find.byType(Button),
              ),
            )
            .onPressed,
        isNull,
      );
      operations.deployment!.completeError(
        DeviceOperationFailure('Previous app restored after cancellation.'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Previous app restored after cancellation.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Button>(
              find.ancestor(
                of: find.text('Back to Toolbox'),
                matching: find.byType(Button),
              ),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'page disposal cancels pending transport without stale state updates',
    (tester) async {
      final device = FakeTransport()..pending = Completer<String>();
      await show(tester, LivePlayerPage(transportFactory: (_, _) => device));
      await tester.tap(find.text('Collect support report'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(device.cancelled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('GUI follows shared SSH account validation including dot names', (
    tester,
  ) async {
    final device = FakeTransport();
    await show(
      tester,
      LivePlayerPage(
        transportFactory: (host, user) {
          SshDeviceTransport(host: host, user: user);
          expect(user, 'tempo.test');
          return device;
        },
      ),
    );
    await tester.enterText(find.byType(TextField).at(1), 'tempo.test');
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connected to tempo.test@'), findsOneWidget);
  });
}
