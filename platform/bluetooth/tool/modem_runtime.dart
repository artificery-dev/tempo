import 'dart:typed_data';

/// MT6582 CCCI runtime ABI for the Y2's reserved modem memory.
/// Generated from addresses and sizes, never from a player's RAM snapshot.
/// Layout reference: android.googlesource.com/kernel/mediatek/+/android-4.4.4_r3/
/// drivers/misc/mediatek/dual_ccci/ccci_md_main.c (runtime setup).
Uint8List modemSharedMemory() {
  final bytes = Uint8List(0x1c4000);
  final data = ByteData.sublistView(bytes);
  final runtime = List<int>.filled(70, 0);
  runtime.setRange(0, 4, [0x46494343, 0x3536544d, 0x31453238, 0x20121001]);
  runtime.setRange(8, 12, [0x41609000, 0xb5000, 0x41601000, 0x8000]);
  runtime[12] = 8; // UART slots; six backed by shared memory.
  for (var i = 0; i < 6; i++) {
    runtime[13 + i] = 0x416d5000 + i * 0x8018;
    runtime[21 + i] = 0x8018;
  }
  runtime.setRange(29, 33, [0x416c0000, 0x14014, 0x416be000, 0x1008]);
  runtime.setRange(35, 37, [0x41600118, 0x800]);
  runtime.setRange(39, 46, [
    0x41705270,
    0x2018,
    0x41707288,
    0x4b000,
    0x41752288,
    0x6fea0,
    3,
  ]);
  for (var i = 0; i < 3; i++) {
    runtime[46 + i] = 0x417c2938 + i * 0xa20;
    runtime[50 + i] = 0x210;
    runtime[54 + i] = 0x417c2128 + i * 0xa20;
    runtime[58 + i] = 0x810;
  }
  runtime.setRange(62, 68, [
    0x41600918,
    0xc,
    0x41705090,
    0xf0,
    0x41600924,
    0x400,
  ]);
  runtime[69] = 0x46494343;
  for (var i = 0; i < runtime.length; i++) {
    data.setUint32(i * 4, runtime[i], Endian.little);
  }
  // misc_info_t: remapping supported; board has the 32 kHz crystal.
  for (final entry in {
    0x924: 0x46494343,
    0x928: 6,
    0x934: 0xbe000000,
    0xa40: 0x46494343,
  }.entries) {
    data.setUint32(entry.key, entry.value, Endian.little);
  }
  return bytes;
}
