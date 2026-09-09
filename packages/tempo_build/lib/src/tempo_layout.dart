import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';

/// Raw eMMC USER offsets, independent of the vendor scatter address space.
class TempoLayout {
  const TempoLayout();
  static const userSize = 0x1d2000000;
  static const bootOffset = 0x2900000;
  static const recoveryOffset = 0x3900000;
  static const bootCapacity = 0x1000000;
  static const splashOffset = 0x4f80000;
  static const rootfsOffset = 0x5180000;
  static const rootfsSize = userSize - rootfsOffset;

  /// One Linux partition, numbered p1 to preserve the existing root device.
  /// Boot-chain data is deliberately outside the host-mountable filesystem.
  static Uint8List partitionTable() {
    final bytes = Uint8List(512);
    final data = ByteData.sublistView(bytes);
    data.setUint32(440, 0x54454d50, Endian.little); // Stable Tempo disk ID.
    bytes.setRange(447, 450, [0xfe, 0xff, 0xff]); // LBA-only CHS sentinel.
    bytes[450] = 0x83;
    bytes.setRange(451, 454, [0xfe, 0xff, 0xff]);
    data.setUint32(454, rootfsOffset ~/ 512, Endian.little);
    data.setUint32(458, rootfsSize ~/ 512, Endian.little);
    bytes[510] = 0x55;
    bytes[511] = 0xaa;
    return bytes;
  }
}

Future<Map<String, Object>> tempoInstallerManifest({
  required Directory directory,
  required String version,
  required String commit,
  required String icon,
}) async {
  if (version.trim().isEmpty)
    throw const FormatException('Missing firmware version');
  final table = directory.childFile('partition-table.bin');
  await table.writeAsBytes(TempoLayout.partitionTable(), flush: true);
  final images = <Map<String, Object>>[];
  // Publish the host partition table last, after the filesystem is written.
  for (final (name, filename, offset, capacity) in [
    ('boot', 'boot.img', TempoLayout.bootOffset, TempoLayout.bootCapacity),
    (
      'recovery',
      'recovery.img',
      TempoLayout.recoveryOffset,
      TempoLayout.bootCapacity,
    ),
    (
      'splash',
      'logo.img',
      TempoLayout.splashOffset,
      TempoLayout.rootfsOffset - TempoLayout.splashOffset,
    ),
    ('rootfs', 'rootfs.ext4', TempoLayout.rootfsOffset, TempoLayout.rootfsSize),
    ('partition-table', 'partition-table.bin', 0, 512),
  ]) {
    final file = directory.childFile(filename);
    final length = await file.length();
    final padded = (length + 511) ~/ 512 * 512;
    if (length == 0 || padded > capacity)
      throw FormatException('$name exceeds its Tempo layout range');
    Stream<List<int>> bytes() async* {
      yield* file.openRead();
      if (padded > length) yield Uint8List(padded - length);
    }

    images.add({
      'file': 'images/$filename',
      'size': padded,
      'sha256': (await sha256.bind(bytes()).first).toString(),
      'writes': [
        {
          'name': name,
          'region': 'user',
          'source_offset': 0,
          'target_offset': offset,
          'length': padded,
        },
      ],
    });
  }
  return {
    'format': 'dev.artificery.tempo.y2-firmware',
    'format_version': 1,
    'device': {
      'id': 'innioasis-y2',
      'hardware_code': 0x6582,
      'hardware_subcode': 0x8a00,
      'storage': {
        'boot1': 0x400000,
        'boot2': 0x400000,
        'user': TempoLayout.userSize,
      },
    },
    'firmware': {
      'id': 'tempo',
      'name': 'Tempo',
      'version': version,
      'commit': commit,
      'icon': icon,
    },
    'images': images,
  };
}
