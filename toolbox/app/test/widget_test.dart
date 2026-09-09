import 'package:tempo_toolbox/emulator/src/event_log.dart';
import 'package:tempo_logger/tempo_logger.dart';
import 'package:tomeui/tomeui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/main.dart';

void main() {
  for (final width in [320.0, 390.0, 800.0, 1200.0]) {
    testWidgets('Toolbox navigation and operation guards at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ProviderScope(child: InstallerApp()));
      await tester.pumpAndSettle();
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(InstallerApp)),
      );
      final router = scope.read(toolboxRouterProvider);
      await Logger(
        tag: 'device',
        writer: scope.read(toolboxLogsProvider),
      ).info('Device ready', metadata: [true, 1]);
      await tester.pumpAndSettle();

      final workspace = tester.state(find.byType(ConnectionPage));
      expect(router.routeInformationProvider.value.uri.path, '/player');
      expect(find.text('Serial [NYI]'), findsOneWidget);
      expect(find.text('Firmware [NYI]'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(
        find.byKey(const ValueKey('toolbox-sidebar')),
        width >= 850 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/settings');
      expect(tester.state(find.byType(ConnectionPage)), same(workspace));
      expect(find.text('Device settings [NYI]'), findsOneWidget);
      expect(find.text('Device settings are coming'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('nav-backup')));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/backup');
      expect(find.byKey(const ValueKey('nav-flash')), findsNothing);
      expect(find.text('Create a backup'), findsNWidgets(3));
      expect(find.text('Log Messages'), findsNothing);
      expect(find.text('Resume a previous backup'), findsNothing);
      expect(find.text('Choose legacy folder'), findsNothing);
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('workflow-next'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workflow-next')));
      await tester.pumpAndSettle();
      expect(find.text('Choose backup destination'), findsOneWidget);
      expect(find.text('Connect and back up'), findsNothing);
      expect(
        tester
            .widget<Button>(find.byKey(const ValueKey('workflow-next')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('operation-Flash'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('operation-Flash')));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('workflow-next'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workflow-next')));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/backup');
      expect(find.text('Choose package'), findsOneWidget);
      expect(find.text('Log Messages'), findsNothing);
      expect(find.text('Logs (1)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('emulator-log-copy-json')),
        findsOneWidget,
      );
      expect(find.text('Write plan [NYI]'), findsNothing);
      expect(find.text('Connect and flash'), findsNothing);
      expect(
        tester
            .widget<Button>(find.byKey(const ValueKey('workflow-next')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
