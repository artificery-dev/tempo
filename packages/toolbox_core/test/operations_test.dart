import 'dart:convert';
import 'dart:io';
import 'package:tempo_usb/tempo_usb.dart';
import 'package:toolbox_core/toolbox_core.dart';
import 'package:test/test.dart';

class FakeEngine extends NativeUsbEngine {
  FakeEngine() : super(executable: 'fake', agent: 'DA.img');
  final calls = <List<String>>[];
  bool preloader = false;

  /// The setup document as the engine would read it, while it exists.
  String? setupDocument;
  @override
  Future<EngineEvent> run(
    List<String> arguments, {
    required void Function(EngineEvent) onEvent,
  }) async {
    calls.add(arguments);
    final setup = arguments.indexOf('--setup');
    if (setup >= 0) {
      setupDocument = await File(arguments[setup + 1]).readAsString();
    }
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
  test(
    'device setup rides along in a private file, for Recovery only',
    () async {
      const setup = DeviceSetup(
        username: 'alice',
        password: 'correct horse',
        hostname: 'alices-y2',
        sshKeys: 'ssh-ed25519 AAAA alice\n\n',
      );
      await operations.install(firmware.path, setup: setup, onEvent: (_) {});
      final arguments = engine.calls.last;
      expect(arguments.sublist(0, 3), [
        'recovery',
        'flash',
        firmware.absolute.path,
      ]);
      expect(arguments[3], '--setup');
      expect(jsonDecode(engine.setupDocument!), {
        'username': 'alice',
        'password': 'correct horse',
        'hostname': 'alices-y2',
        'ssh_keys': ['ssh-ed25519 AAAA alice'],
      });
      expect(
        File(arguments[4]).existsSync(),
        isFalse,
        reason: 'gone after the run',
      );
      await operations.install(
        firmware.path,
        setup: const DeviceSetup(),
        onEvent: (_) {},
      );
      expect(engine.calls.last, isNot(contains('--setup')));
      await expectLater(
        operations.install(
          firmware.path,
          setup: setup,
          legacyDownloadAgent: true,
          onEvent: (_) {},
        ),
        throwsStateError,
      );
      await expectLater(
        operations.install(
          firmware.path,
          setup: const DeviceSetup(username: 'root'),
          onEvent: (_) {},
        ),
        throwsArgumentError,
      );
    },
  );
  test('device setup checks what the player would refuse', () {
    expect(const DeviceSetup().validate(), isEmpty);
    expect(const DeviceSetup().isEmpty, isTrue);
    const fine = DeviceSetup(
      username: '_svc-1',
      hostname: 'Y2-one',
      timezone: 'America/Argentina/Buenos_Aires',
      locale: 'ast_ES.UTF-8',
      sshKeys: 'sk-ssh-ed25519@openssh.com AAAA',
    );
    expect(fine.validate(), isEmpty);
    expect(fine.configured, [
      'Account name',
      'Device name',
      'Time zone',
      'Language',
      'SSH keys',
    ]);
    final wrong = const DeviceSetup(
      username: 'Alice',
      hostname: '-y2',
      timezone: 'Europe/../shadow',
      locale: 'english',
      sshKeys: 'rsa AAAA',
    ).validate();
    expect(wrong.keys, [
      'username',
      'hostname',
      'timezone',
      'locale',
      'ssh_keys',
    ]);
    expect(
      DeviceSetup.fromJson({
        'hostname': 'y2',
        'ssh_keys': ['ssh-ed25519 A', 'ssh-ed25519 B'],
      }).keys,
      ['ssh-ed25519 A', 'ssh-ed25519 B'],
    );
    expect(
      () => DeviceSetup.fromJson({'colour': 'red'}),
      throwsFormatException,
    );
    expect(() => DeviceSetup.fromJson({'username': 7}), throwsFormatException);
  });
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
