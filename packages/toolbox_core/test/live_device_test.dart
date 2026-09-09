import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:toolbox_core/live_device.dart';
import 'package:test/test.dart';

class FakeDevice implements DeviceTransport {
  final memory = Uint8List(65536);
  final files = <String, Uint8List>{};
  final events = <String>[];
  bool wrongCapacity = false,
      corruptTransfer = false,
      corruptReadback = false,
      shortRead = false,
      written = false;
  @override
  Future<String> command(List<String> args, {bool root = false}) async {
    events.add(args.join(' '));
    switch (args.first) {
      case 'true':
      case 'sync':
      case 'mountpoint':
        return '';
      case 'blockdev':
        return wrongCapacity ? '32768' : '65536';
      case 'sha256sum':
        return '${sha256.convert(files[args.last]!)}  ${args.last}';
      case 'rm':
        files.remove(args.last);
        return '';
      case 'df':
        return 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/card 200000 100 100000 1% /mnt/sd';
      case 'touch':
        files[args.last] = Uint8List(0);
        return '';
      case 'dd':
        final source = args
            .firstWhere((arg) => arg.startsWith('if='))
            .substring(3);
        final offset =
            int.parse(
              args.firstWhere((arg) => arg.startsWith('seek=')).substring(5),
            ) *
            4096;
        memory.setRange(offset, offset + files[source]!.length, files[source]!);
        written = true;
        return '';
      default:
        throw StateError(args.join(' '));
    }
  }

  @override
  Future<String> shell(String command, {bool root = false}) async {
    events.add(command);
    return '';
  }

  @override
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  }) async* {
    final input = path == '/dev/mmcblk0' ? memory : files[path]!;
    final bytes = Uint8List.fromList(input.sublist(offset, offset + length));
    if (corruptReadback && written && bytes.isNotEmpty)
      bytes[bytes.length - 1] ^= 1;
    final end = shortRead ? bytes.length - 1 : bytes.length;
    for (var start = 0; start < end; start += 4090)
      yield bytes.sublist(start, start + 4090 > end ? end : start + 4090);
  }

  @override
  Future<void> upload(
    File source,
    String destination, {
    bool root = false,
  }) async {
    events.add('upload $destination');
    files[destination] = source.readAsBytesSync();
    if (corruptTransfer) files[destination]![0] ^= 1;
  }

  @override
  Future<void> cancel() async {
    events.add('cancel');
  }
}

const geometry = DeviceGeometry(
  emmcSize: 65536,
  bootOffset: 4096,
  bootSize: 4096,
  logoSize: 4096,
  logoScanSize: 32768,
);
Uint8List logo() {
  final bytes = Uint8List(528), view = ByteData(528);
  view.setUint32(0, 0x58881688, Endian.little);
  view.setUint32(4, 16, Endian.little);
  view.setUint32(512, 1, Endian.little);
  view.setUint32(516, 16, Endian.little);
  bytes.setAll(0, view.buffer.asUint8List());
  bytes.setAll(8, ascii.encode('LOGO'));
  return bytes;
}

void main() {
  late Directory temporary;
  late FakeDevice transport;
  late LiveDeviceOperations device;
  late File boot;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('tempo-live-test-');
    transport = FakeDevice();
    device = LiveDeviceOperations(transport);
    boot = File('${temporary.path}/boot.img')
      ..writeAsBytesSync([
        ...ascii.encode('ANDROID!'),
        ...List.filled(1000, 42),
      ]);
    transport.memory.setAll(4096, ascii.encode('ANDROID!'));
    transport.memory.setAll(16384, logo());
  });
  tearDown(() => temporary.deleteSync(recursive: true));
  test('boot validates transfer and readback before reboot', () async {
    await device.flashBoot(boot, geometry);
    expect(
      transport.memory.sublist(4096, 4096 + boot.lengthSync()),
      boot.readAsBytesSync(),
    );
    expect(transport.events.last, contains('sleep 1; reboot'));
    expect(transport.files, isEmpty);
  });
  test('capacity mismatch refuses upload or write', () async {
    transport.wrongCapacity = true;
    await expectLater(
      device.flashBoot(boot, geometry),
      throwsA(isA<DeviceOperationFailure>()),
    );
    expect(transport.events.any((event) => event.startsWith('upload')), false);
    expect(transport.written, false);
  });
  test('existing boot magic is required unless explicitly forced', () async {
    transport.memory.fillRange(4096, 4104, 0);
    await expectLater(
      device.flashBoot(boot, geometry),
      throwsA(isA<DeviceOperationFailure>()),
    );
    expect(transport.written, false);
    await device.flashBoot(boot, geometry, force: true, rebootAfter: false);
    expect(transport.written, true);
  });
  test('corrupt transfer never writes and clears temporary file', () async {
    transport.corruptTransfer = true;
    await expectLater(
      device.flashBoot(boot, geometry),
      throwsA(isA<DeviceOperationFailure>()),
    );
    expect(transport.written, false);
    expect(transport.files, isEmpty);
  });
  test('readback mismatch never reboots', () async {
    transport.corruptReadback = true;
    await expectLater(
      device.flashBoot(boot, geometry),
      throwsA(isA<DeviceOperationFailure>()),
    );
    expect(transport.written, true);
    expect(transport.events.any((event) => event.contains('reboot')), false);
  });
  test('dry-run verifies transfer without writing or rebooting', () async {
    await device.flashBoot(boot, geometry, dryRun: true);
    expect(transport.events.any((event) => event.startsWith('upload')), true);
    expect(transport.written, false);
    expect(transport.events.any((event) => event.contains('reboot')), false);
  });
  test('short reads cannot be mistaken for valid checksums', () async {
    transport.shortRead = true;
    await expectLater(
      device.flashBoot(boot, geometry),
      throwsA(isA<DeviceOperationFailure>()),
    );
    expect(transport.written, false);
  });
  test(
    'LOGO scan survives chunk boundaries and backs up before writing',
    () async {
      final image = File('${temporary.path}/logo.bin')
        ..writeAsBytesSync(logo());
      final backup = File('${temporary.path}/backup.bin');
      final location = await device.flashLogo(image, geometry, backup: backup);
      expect(location.offset, 16384);
      expect(backup.readAsBytesSync(), logo());
      expect(transport.written, true);
    },
  );
  test('multiple LOGO hits are refused without backup or upload', () async {
    transport.memory.setAll(24576, logo());
    final image = File('${temporary.path}/logo.bin')..writeAsBytesSync(logo());
    final backup = File('${temporary.path}/backup.bin');
    await expectLater(
      device.flashLogo(image, geometry, backup: backup),
      throwsA(isA<DeviceOperationFailure>()),
    );
    expect(backup.existsSync(), false);
    expect(transport.written, false);
  });
  test('reinstall flag is only set after matching card checksum', () async {
    final image = File('${temporary.path}/rootfs.gz')
      ..writeAsBytesSync([31, 139, ...List.filled(50, 3)]);
    transport.corruptTransfer = true;
    await expectLater(
      device.installRootfs(image, 'tempo'),
      throwsA(isA<DeviceOperationFailure>()),
    );
    expect(transport.files.containsKey('/mnt/sd/FORCE_REINSTALL'), false);
    transport.corruptTransfer = false;
    await device.installRootfs(image, 'tempo');
    expect(transport.files.containsKey('/mnt/sd/FORCE_REINSTALL'), true);
  });
  test(
    'app deployment dry-run validates bundle mode and destination locally',
    () async {
      final bundle = Directory('${temporary.path}/bundle')..createSync();
      Future<void> deploy(String destination, {bool release = false}) =>
          device.deployBundle(
            bundle,
            release: release,
            destination: destination,
            flutterPi: '/usr/local/bin/flutter-pi',
            engineDirectory: '/usr/lib',
            pixelFormat: 'RGB565',
            vmServicePort: 41200,
            dryRun: true,
          );
      await expectLater(
        deploy('/opt/tempo', release: true),
        throwsA(isA<DeviceOperationFailure>()),
      );
      await expectLater(deploy('/'), throwsA(isA<DeviceOperationFailure>()));
      await expectLater(
        deploy('/opt/../'),
        throwsA(isA<DeviceOperationFailure>()),
      );
      await deploy('/opt/tempo/flutter_assets');
      expect(transport.events, isEmpty);
    },
  );
  test('remote command quoting preserves metacharacters as data', () {
    expect(
      quoteRemote("name with '\$() `ticks`"),
      "'name with '\\''\$() `ticks`'",
    );
  });
}
