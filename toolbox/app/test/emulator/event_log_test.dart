import 'dart:convert';
import 'package:tempo_logger/tempo_logger.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/emulator/src/event_log.dart';
import 'package:tempo_toolbox/emulator/src/event_log_panel.dart';
import 'package:tempo_toolbox/emulator/src/rig_panel.dart';
import 'package:tomeui/tomeui.dart';

void main() {
  test('structured history snapshots fields and exports bounded JSONL', () {
    final log = EmulatorEventLog(capacity: 2);
    addTearDown(log.dispose);
    final fields = <String, Object?>{
      'stackTrace': 'trace\nframe',
      'nested': {
        'values': [1, true, null],
      },
    };
    final entry = LogRecord(
      message: 'line one\nline two',
      metadata: fields,
      tag: 'decoder',
      level: LogLevel.error,
      timestamp: DateTime.utc(2026),
    );
    fields.clear();
    log.write(
      LogRecord(tag: 'test', level: LogLevel.info, message: 'discard me'),
    );
    log.write(entry);
    log.write(LogRecord(tag: 'test', level: LogLevel.info, message: 'latest'));
    expect(log.length, 2);
    final lines = log.jsonLines
        .split('\n')
        .map((line) => jsonDecode(line))
        .toList();
    expect(lines.first['metadata']['nested']['values'], [1, true, null]);
    expect(lines.first['level'], 'error');
    expect(lines.first['tag'], 'decoder');
    expect(lines.first['metadata']['stackTrace'], 'trace\nframe');
    expect(lines.first['message'], 'line one\nline two');
    expect(log.text, contains(r'trace\nframe'));
    expect(log.text, isNot(contains('discard me')));
  });

  testWidgets('control cards start closed and animate open', (tester) async {
    await tester.pumpWidget(
      const TomeApp(
        home: EmulatorControlCard(
          title: 'Example',
          icon: LucideIcons.battery,
          child: SizedBox(height: 100, child: Text('Details')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final details = tester.element(find.text('Details'));
    expect(
      details.findAncestorWidgetOfExactType<IgnorePointer>()!.ignoring,
      isTrue,
    );
    await tester.tapAt(
      tester.getTopLeft(find.byType(EmulatorControlCard)) + const Offset(8, 8),
    );
    await tester.pumpAndSettle();
    expect(
      details.findAncestorWidgetOfExactType<IgnorePointer>()!.ignoring,
      isFalse,
    );
  });

  testWidgets(
    'sources are discovered, sorted, multiselected and applied to copies',
    (tester) async {
      final log = EmulatorEventLog(capacity: 3);
      addTearDown(log.dispose);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await Logger(tag: 'restore', writer: log).info('Restore event');
      final emulator = Logger(tag: 'emulator', writer: log);
      await Logger(
        tag: 'hardware',
        parent: emulator,
        writer: log,
      ).info('Emulator event');
      await tester.pumpWidget(
        TomeApp(
          home: EmulatorLogDock(log: log, child: const SizedBox.expand()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emulator-log-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('log-source-dropdown')));
      await tester.pumpAndSettle();
      expect(log.sources, ['emulator', 'restore']);
      expect(find.byKey(const ValueKey('log-source-device')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('log-source-emulator'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('log-source-restore')))
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('log-source-emulator')));
      await tester.pumpAndSettle();
      await Logger(tag: 'backup', writer: log).info('Backup event');
      await tester.pumpAndSettle();
      expect(log.sources, ['backup', 'emulator', 'restore']);
      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('log-source-backup')))
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('log-source-emulator')))
            .value,
        isFalse,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('log-source-backup'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('log-source-emulator')))
              .dy,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Emulator event'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('emulator-log-copy-json')));
      await tester.pumpAndSettle();
      expect(clipboard!.split('\n').map((line) => jsonDecode(line)['tag']), [
        'restore',
        'backup',
      ]);
      await tester.tap(find.byKey(const ValueKey('log-source-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('log-source-backup')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('log-source-restore')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('No logs from selected sources.'), findsOneWidget);
      expect(
        tester
            .widget<Button>(
              find.byKey(const ValueKey('emulator-log-copy-json')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [288.0, 1200.0]) {
    testWidgets(
      'log slides over workspace and copies structured entries at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 680);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final log = EmulatorEventLog();
        addTearDown(log.dispose);
        log.write(
          LogRecord(
            message: 'Decode failed',
            tag: 'video',
            level: LogLevel.error,
            metadata: {
              'frame': 42,
              'codec': {'name': 'h264'},
            },
          ),
        );
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          TomeApp(
            home: EmulatorLogDock(
              log: log,
              child: const SizedBox.expand(key: ValueKey('workspace')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final workspace = tester.getRect(
          find.byKey(const ValueKey('workspace')),
        );
        final toggle = find.byKey(const ValueKey('emulator-log-toggle'));
        final closedTop = tester.getTopLeft(toggle).dy;
        await tester.tap(toggle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final movingTop = tester.getTopLeft(toggle).dy;
        await tester.pumpAndSettle();
        expect(movingTop, lessThan(closedTop));
        expect(movingTop, greaterThan(tester.getTopLeft(toggle).dy));
        expect(
          tester.getRect(find.byKey(const ValueKey('workspace'))),
          workspace,
        );
        expect(
          tester.getCenter(find.byKey(const ValueKey('log-expand-0'))).dy,
          tester.getCenter(find.byKey(const ValueKey('log-copy-0'))).dy,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('logs-toolbar'))).dy,
          greaterThan(tester.getTopLeft(toggle).dy),
        );
        expect(find.textContaining('"frame": 42'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('log-expand-0')));
        await tester.pumpAndSettle();
        expect(find.textContaining('"frame": 42'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('emulator-log-copy-json')));
        await tester.pumpAndSettle();
        expect(jsonDecode(clipboard!)['metadata']['codec']['name'], 'h264');
        await tester.tap(find.byKey(const ValueKey('emulator-log-copy-text')));
        await tester.pumpAndSettle();
        expect(clipboard, contains('[error] video: Decode failed'));
        if (width > 480) expect(find.text('Copied'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 125));
        expect(find.text('Copied'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text('Copied'), findsNothing);
        final clear = find.byKey(const ValueKey('logs-clear'));
        expect(
          tester.getTopRight(clear).dx,
          lessThan(
            tester.getTopRight(find.byKey(const ValueKey('logs-toolbar'))).dx -
                8,
          ),
        );
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(log.length, 0);
        expect(log.sources, isEmpty);
        expect(find.text('Logs (0)'), findsOneWidget);

        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(toggle).dy, closedTop);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
