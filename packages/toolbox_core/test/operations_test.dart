import 'dart:io';
import 'package:tempo_usb/tempo_usb.dart';
import 'package:toolbox_core/toolbox_core.dart';
import 'package:test/test.dart';

class FakeEngine extends NativeUsbEngine {
  FakeEngine() : super(executable: 'fake', agent: 'DA.img');
  final calls = <List<String>>[];
  bool preloader = false;
  @override
  Future<EngineEvent> run(
    List<String> arguments, {
    required void Function(EngineEvent) onEvent,
  }) async {
    calls.add(arguments);
    return arguments.first == 'inspect-firmware'
        ? {'event': 'firmware-info', 'includes_preloader': preloader}
        : {'event': 'result'};
  }
}

void main() {
  late Directory folder;
  late File firmware;
  late FakeEngine engine;
  late ToolboxOperations operations;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('toolbox-policy-');
    firmware = await File(
      '${folder.path}/firmware.y2-firmware',
    ).writeAsString('fixture');
    engine = FakeEngine();
    operations = ToolboxOperations(engine: engine);
  });
  tearDown(() => folder.delete(recursive: true));
  test(
    'install verifies before writing and preserves explicit authorization',
    () async {
      engine.preloader = true;
      await operations.install(firmware.path, onEvent: (_) {});
      expect(engine.calls.map((c) => c.first), [
        'inspect-firmware',
        'recovery',
      ]);
      expect(engine.calls.last, ['recovery', 'flash', firmware.absolute.path]);
      await operations.install(
        firmware.path,
        allowPreloader: true,
        onEvent: (_) {},
      );
      expect(engine.calls.last, [
        'recovery',
        'flash',
        firmware.absolute.path,
        '--allow-preloader',
      ]);
    },
  );
  for (final legacy in [false, true]) {
    test('transfer routing, legacy=$legacy', () async {
      final configured = ToolboxOperations(
        engine: engine,
        preloader: firmware.path,
      );
      final output = '${folder.path}/backup.gz';
      await configured.backup(
        output,
        legacyDownloadAgent: legacy,
        onEvent: (_) {},
      );
      expect(engine.calls.last, [
        if (!legacy) 'recovery',
        'backup',
        if (legacy) 'DA.img',
        output,
        if (legacy) ...['--preloader', firmware.absolute.path],
      ]);
      await configured.restore(
        firmware.path,
        legacyDownloadAgent: legacy,
        allowPreloader: true,
        resume: true,
        onEvent: (_) {},
      );
      expect(engine.calls.last, [
        if (!legacy) 'recovery',
        'restore',
        if (legacy) 'DA.img',
        firmware.absolute.path,
        '--allow-preloader',
        '--resume',
        if (legacy) ...['--preloader', firmware.absolute.path],
      ]);
      await configured.install(
        firmware.path,
        legacyDownloadAgent: legacy,
        onEvent: (_) {},
      );
      expect(engine.calls.last, [
        if (!legacy) 'recovery',
        'flash',
        if (legacy) 'DA.img',
        firmware.absolute.path,
        if (legacy) ...['--preloader', firmware.absolute.path],
      ]);
    });
  }
  test(
    'readback can be explicitly disabled for either write transport',
    () async {
      for (final legacy in [false, true]) {
        await operations.install(
          firmware.path,
          legacyDownloadAgent: legacy,
          verifyWrite: false,
          onEvent: (_) {},
        );
        expect(engine.calls.last, contains('--no-verify'));
        await operations.restore(
          firmware.path,
          legacyDownloadAgent: legacy,
          verifyWrite: false,
          onEvent: (_) {},
        );
        expect(engine.calls.last, contains('--no-verify'));
        await operations.install(
          firmware.path,
          legacyDownloadAgent: legacy,
          onEvent: (_) {},
        );
        expect(engine.calls.last, isNot(contains('--no-verify')));
      }
    },
  );
  test('raw policy passes explicit target, backup and guard options', () async {
    final safety = '${folder.path}/safety.img';
    await operations.installRaw(
      'bootimg',
      firmware.path,
      safety,
      dryRun: true,
      forceBootHeader: true,
      onEvent: (_) {},
    );
    expect(engine.calls.single, [
      'flash-raw',
      'DA.img',
      'BOOTIMG',
      firmware.absolute.path,
      File(safety).absolute.path,
      '--dry-run',
      '--force-boot-header',
    ]);
  });
  test(
    'raw policy rejects protected targets, logo override and occupied backup',
    () async {
      final safety = '${folder.path}/safety.img';
      for (final target in ['BOOT1', 'BOOT2', 'RPMB', 'UBOOT']) {
        await expectLater(
          operations.installRaw(target, firmware.path, safety, onEvent: (_) {}),
          throwsArgumentError,
        );
      }
      await expectLater(
        operations.installRaw(
          'LOGO',
          firmware.path,
          safety,
          forceBootHeader: true,
          onEvent: (_) {},
        ),
        throwsArgumentError,
      );
      await File('$safety.logo.img').writeAsString('preserve');
      await expectLater(
        operations.installRaw('LOGO', firmware.path, safety, onEvent: (_) {}),
        throwsStateError,
      );
      await expectLater(
        operations.installRaw(
          'BOOTIMG',
          firmware.path,
          firmware.path,
          onEvent: (_) {},
        ),
        throwsStateError,
      );
      expect(engine.calls, isEmpty);
    },
  );
  test('backup refuses existing files without starting USB', () async {
    await expectLater(
      operations.backup(firmware.path, onEvent: (_) {}),
      throwsStateError,
    );
    expect(engine.calls, isEmpty);
  });
  test('missing firmware and invalid timeout never start USB', () async {
    await expectLater(
      operations.inspectFirmware('${folder.path}/absent'),
      throwsArgumentError,
    );
    expect(
      () => operations.probe(seconds: -1, onEvent: (_) {}),
      throwsArgumentError,
    );
    expect(engine.calls, isEmpty);
  });
  test('explicit DA and EMI input reach the shared read operation', () async {
    final configured = ToolboxOperations(
      engine: engine,
      agent: firmware.path,
      preloader: firmware.path,
    );
    await configured.partitions(onEvent: (_) {});
    expect(engine.calls.single, [
      'partitions',
      firmware.absolute.path,
      '--preloader',
      firmware.absolute.path,
    ]);
  });
}
