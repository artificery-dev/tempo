import 'modem_runtime.dart';
import 'modem_filesystem.dart';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:tempo_build/tempo_build.dart';

final clock = Stopwatch()..start();
void modemLog(String value) => stdout.writeln(
  '${(clock.elapsedMicroseconds / 1e6).toStringAsFixed(3)}: $value',
);

final class ModemHardware {
  ModemHardware(this.library) {
    fd = library.lookupFunction<Int32 Function(), int Function()>('md_open')();
    if (fd < 0) throw const FileSystemException('Cannot open /dev/mem');
    try {
      final map = library
          .lookupFunction<
            Pointer<Void> Function(Int32, Uint64, Uint32),
            Pointer<Void> Function(int, int, int)
          >('md_map');
      for (final region in [
        (0x10001000, 0x1000),
        (0x10006000, 0x1000),
        (0x1020a000, 0x1000),
        (0x20050000, 0x1000),
        (0x20190000, 0x6000),
        (modemRom, modemRomSize),
        (modemSmem, modemSmemSize),
      ]) {
        final address = map(fd, region.$1, region.$2).cast<Uint8>();
        if (address == nullptr)
          throw StateError(
            'Cannot map modem address ${region.$1.toRadixString(16)}',
          );
        maps[region.$1] = (address, region.$2);
      }
    } catch (_) {
      close();
      rethrow;
    }
  }
  final DynamicLibrary library;
  late final int fd;
  final maps = <int, (Pointer<Uint8>, int)>{};
  late final _read = library
      .lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('md_read32', isLeaf: true);
  late final _write = library
      .lookupFunction<
        Void Function(Pointer<Void>, Uint32),
        void Function(Pointer<Void>, int)
      >('md_write32', isLeaf: true);
  int tx = 0;
  bool cancelled = false, cleaning = false;

  Pointer<Void> pointer(int address) {
    if (address & 3 != 0) throw const FormatException('Unaligned MMIO access');
    for (final entry in maps.entries) {
      if (address >= entry.key && address <= entry.key + entry.value.$2 - 4)
        return (entry.value.$1 + address - entry.key).cast();
    }
    throw StateError('Unmapped MMIO address');
  }

  int read(int address) => _read(pointer(address));
  void write(int address, int value) => _write(pointer(address), value);
  void change(int address, {int clear = 0, int set = 0}) =>
      write(address, (read(address) & ~clear) | set);
  List<int> status() => [read(0x1000660c), read(0x10006610)];
  Uint8List region(int base) => maps[base]!.$1.asTypedList(maps[base]!.$2);
  void checkCancellation() {
    if (cancelled && !cleaning) throw StateError('Bootstrap interrupted');
  }

  Future<void> wait(
    bool Function() ready,
    String label, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final deadline = clock.elapsed + timeout;
    while (!ready()) {
      checkCancellation();
      if (clock.elapsed >= deadline) throw TimeoutException(label);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> powerOn() async {
    write(0x10006000, 0x0b160001);
    change(0x10006284, set: 4);
    change(0x10006284, set: 8);
    await wait(() => status().every((v) => v & 1 != 0), 'MD1 power-on status');
    change(0x10006284, clear: 16);
    change(0x10006284, clear: 2);
    change(0x10006284, set: 1);
    change(0x10006284, clear: 256);
    change(0x10001220, clear: 0xb8);
    await wait(() => read(0x10001228) & 0xb8 == 0, 'MD1 bus unprotect');
  }

  Future<void> powerOff() async {
    write(0x10006000, 0x0b160001);
    change(0x10001220, set: 0xb8);
    try {
      await wait(() => read(0x10001228) & 0xb8 == 0xb8, 'MD1 bus protect');
    } on TimeoutException {
      modemLog(
        'WARNING: bus protection timeout; continuing audited vendor power-down',
      );
    }
    change(0x10006284, set: 256);
    change(0x10006284, set: 2);
    change(0x10006284, clear: 1, set: 16);
    change(0x10006284, clear: 12);
    await wait(() => status().every((v) => v & 1 == 0), 'MD1 power-off status');
    modemLog('MD1 hardware OFF');
  }

  Future<void> send(List<int> words) async {
    final bit = 1 << tx;
    await wait(() => read(0x1020a004) & bit == 0, 'CCIF TX busy');
    write(0x1020a004, bit);
    for (var i = 0; i < words.length; i++) {
      write(0x1020a100 + tx * 16 + i * 4, words[i]);
    }
    write(0x1020a00c, tx);
    tx = (tx + 1) & 7;
    modemLog(
      'TX ${words.map((v) => v.toRadixString(16).padLeft(8, '0')).join(' ')}',
    );
  }

  void initialize(Uint8List firmware) {
    region(modemRom).fillRange(0, modemRomSize, 0);
    region(modemRom).setRange(0, firmware.length, firmware);
    region(modemSmem).setAll(0, modemSharedMemory());
    const invalid = 0x40000000;
    final mappings = <int, List<int>>{
      0x300: [
        modemRom - 0x80000000,
        for (var i = 7; i < 10; i++) invalid + 0x2000000 * i,
      ],
      0x304: [for (var i = 10; i < 14; i++) invalid + 0x2000000 * i],
      0x308: [
        modemRom - 0x80000000,
        for (var i = 0; i < 3; i++) invalid + 0x2000000 * i,
      ],
      0x30c: [for (var i = 3; i < 7; i++) invalid + 0x2000000 * i],
    };
    for (final entry in mappings.entries) {
      var value = 0;
      for (var i = 0; i < entry.value.length; i++) {
        value |= (((entry.value[i] >> 24) | 1) & 255) << (8 * i);
      }
      write(0x10001000 + entry.key, value);
    }
    write(0x1020a000, 1);
    write(0x1020a014, 255);
    for (var offset = 0x100; offset < 0x200; offset += 4) {
      write(0x1020a000 + offset, 0);
    }
  }

  Future<void> run(ModemFileSystem filesystem, Directory output) async {
    await powerOn();
    write(0x20050000, 0x2200);
    write(0x2019379c, 0x3567c766);
    write(0x20190000, 0);
    write(0x20195488, 0xa3b66175);
    final deadline = clock.elapsed + const Duration(seconds: 30);
    Duration? readyAt;
    var lastRequest = clock.elapsed;
    var stage = 0, rx = 0, served = 0;
    final smem = region(modemSmem);
    while (clock.elapsed < deadline) {
      checkCancellation();
      if (readyAt != null &&
          clock.elapsed - readyAt >= const Duration(seconds: 5) &&
          clock.elapsed - lastRequest >= const Duration(seconds: 5)) {
        modemLog(
          'Post-ready initialization complete; consumed $served FS records',
        );
        return;
      }
      final pending = read(0x1020a010) & 255;
      if (pending == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        continue;
      }
      for (var n = 0; n < 8; n++) {
        final slot = rx;
        rx = (rx + 1) & 7;
        if (pending & (1 << slot) == 0) continue;
        final words = [
          for (var i = 0; i < 4; i++) read(0x1020a180 + 16 * slot + i * 4),
        ];
        write(0x1020a014, 1 << slot);
        modemLog(
          'RX ${words.map((v) => v.toRadixString(16).padLeft(8, '0')).join(' ')}',
        );
        final [address, size, channel, reserved] = words;
        if (channel == 0) {
          if (size == 0 && reserved == 0x5555ffff && stage == 0) {
            final bytes = ByteData.sublistView(smem);
            final tag = [
              for (var i = 0; i < 4; i++) bytes.getUint32(i * 4, Endian.little),
              modemGuestSmem,
              0x118,
              0x46494343,
            ];
            for (var i = 0; i < tag.length; i++) {
              write(0x1020a140 + i * 4, tag[i]);
            }
            await send([0xffffffff, 0, 1, 0x5555ffff]);
            stage = 1;
          } else if (size == 0 && stage == 1) {
            readyAt = clock.elapsed;
            stage = 2;
            modemLog('NORMAL_BOOT_ID; served $served FS requests');
          } else {
            throw StateError('Unexpected modem control message $words');
          }
        } else if ([23, 27, 31].contains(channel) &&
            address == 0xffffffff &&
            size == 0) {
          modemLog('Consumed unused cellular TX credit');
        } else if (channel == 4 &&
            address == 0xffffffff &&
            size == 0xaf700000 &&
            reserved == 0) {
          modemLog('Consumed unused PCM startup notification');
        } else if (channel == 10 &&
            address == 0xffffffff &&
            size == 0 &&
            reserved == 1) {
          modemLog('Consumed unopened modem tty notification');
        } else if (channel == 14) {
          if (reserved >= 5 ||
              address !=
                  modemGuestSmem + modemFsOffset + reserved * modemFsStride)
            throw StateError('FS buffer address/index mismatch');
          if (size < 8 || size > modemFsStride)
            throw StateError('FS length outside buffer');
          final offset = modemFsOffset + reserved * modemFsStride;
          final packet = Uint8List.fromList(
            smem.sublist(offset, offset + size),
          );
          final request = parseModemRequest(packet);
          final reply = filesystem.respond(request);
          lastRequest = clock.elapsed;
          served++;
          smem.setRange(offset, offset + reply.length, reply);
          await send([address, reply.length, 15, reserved]);
        } else {
          if (address >= modemGuestSmem &&
              address < modemGuestSmem + modemSmemSize &&
              size > 0 &&
              size <= modemFsStride) {
            final off = address - modemGuestSmem;
            final end = (off + size).clamp(0, smem.length);
            await File(
              '${output.path}/channel-$channel-$served.bin',
            ).writeAsBytes(smem.sublist(off, end));
          }
          throw StateError('Unimplemented CCCI channel $channel');
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    throw TimeoutException(
      'Modem boot deadline; stage=$stage, FS requests=$served',
    );
  }

  void close() {
    final unmap = library
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)
        >('md_unmap');
    for (final region in maps.values) {
      unmap(region.$1.cast(), region.$2);
    }
    maps.clear();
    library.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'md_close',
    )(fd);
  }
}
