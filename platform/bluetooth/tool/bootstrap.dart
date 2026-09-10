import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'modem_filesystem.dart';
import 'package:tempo_build/tempo_build.dart';
import 'modem_hardware.dart';

Future<void> checkBoard(DynamicLibrary library) async {
  if (library.lookupFunction<Int32 Function(), int Function()>('md_euid')() !=
      0)
    throw StateError('Root required');
  final compatible = (await File(
    '/proc/device-tree/compatible',
  ).readAsString()).split('\x00');
  if (!compatible.contains('innioasis,y2') ||
      !compatible.contains('mediatek,mt6582'))
    throw StateError('Only audited Innioasis Y2/MT6582 supported');
  if (await Directory('/sys/kernel/ccci').exists())
    throw StateError('Refusing to compete with stock CCCI driver');
  final regions = <(int, int)>[];
  for (final line in await File('/proc/iomem').readAsLines()) {
    final match = RegExp(
      r'^\s*([0-9a-f]+)-([0-9a-f]+) : System RAM$',
    ).firstMatch(line);
    if (match != null)
      regions.add((
        int.parse(match[1]!, radix: 16),
        int.parse(match[2]!, radix: 16),
      ));
  }
  if (regions.isEmpty || regions.every((r) => r.$2 == 0))
    throw StateError('RAM map unavailable or redacted');
  if (regions.any((r) => r.$1 < modemSmem + modemSmemSize && r.$2 >= modemRom))
    throw StateError('Modem buffers overlap Linux System RAM');
}

Future<void> main(List<String> arguments) async {
  final args = [...arguments];
  final validate = args.remove('--validate-only'),
      cleanup = args.remove('--cleanup');
  if (args.contains('--help')) {
    stdout.writeln(
      'bootstrap FIRMWARE [--validate-only|--cleanup] [--output DIR] [--native-library FILE]',
    );
    return;
  }
  String option(String key, String fallback) {
    final at = args.indexOf(key);
    if (at < 0) return fallback;
    if (at + 1 >= args.length) throw FormatException('$key requires a value');
    final result = args[at + 1];
    args.removeRange(at, at + 2);
    return result;
  }

  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  ModemHardware? hardware;
  DynamicLibrary? library;
  int? lock;
  final owned = File('/run/tempo-modem-bootstrap.owned');
  try {
    final output = Directory(
      option('--output', '/var/log/tempo-modem-bootstrap'),
    );
    final native = option(
      '--native-library',
      '${File(Platform.resolvedExecutable).parent.path}/mmio.so',
    );
    if (args.length != 1 || args.single.startsWith('--'))
      throw const FormatException('Expected one vendor modem firmware file');
    if (cleanup) {
      if (!await owned.exists()) return;
      library = DynamicLibrary.open(native);
      await checkBoard(library);
      lock = library.lookupFunction<Int32 Function(), int Function()>(
        'md_lock',
      )();
      if (lock < 0) throw StateError('Another bootstrap owns the modem lock');
      hardware = ModemHardware(library)..cleaning = true;
      await hardware.powerOff();
      await owned.delete();
      return;
    }
    final firmware = await File(args.single).readAsBytes();
    if (sha256.convert(firmware).toString() != modemFirmwareHash ||
        firmware.length > modemRomSize) {
      throw const FormatException('Unexpected Y2 vendor modem firmware');
    }
    modemLog('Validated vendor firmware; generated runtime and RAM filesystem');
    if (validate) return;
    library = DynamicLibrary.open(native);
    await checkBoard(library);
    await output.create(recursive: true);
    lock = library.lookupFunction<Int32 Function(), int Function()>(
      'md_lock',
    )();
    if (lock < 0) throw StateError('Another bootstrap owns the modem lock');
    final hw = hardware = ModemHardware(library);
    final normalize = hw.status().any((v) => v & 1 != 0);
    if (normalize) {
      const untouched = [
        0x10001300,
        0x10001304,
        0x10001308,
        0x1000130c,
        0x1020a000,
        0x1020a004,
        0x1020a010,
        0x20195488,
      ];
      if (untouched.any((a) => hw.read(a) != 0))
        throw StateError('MD1 already powered/configured; refusing ownership');
    }
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      subscriptions.add(
        signal.watch().listen((_) {
          hw.cancelled = true;
        }),
      );
    }
    await owned.writeAsString(
      await File('/proc/sys/kernel/random/boot_id').readAsString(),
      flush: true,
    );
    try {
      if (normalize) {
        modemLog('Normalizing unconfigured LK modem to OFF');
        await hw.powerOff();
      }
      hw.initialize(firmware);
      await hw.run(ModemFileSystem(), output);
    } finally {
      hw.cleaning = true;
      await hw.powerOff();
      await owned.delete();
    }
  } catch (error) {
    stderr.writeln('modem bootstrap: $error');
    exitCode = 1;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    hardware?.close();
    if (lock != null && lock >= 0)
      library!.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'md_close',
      )(lock);
    await stdout.flush();
  }
}
