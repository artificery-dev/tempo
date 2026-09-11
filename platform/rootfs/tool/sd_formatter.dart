import 'dart:io';

/// The formatter accepts no caller-supplied device path. eMMC is never a target.
class SdFormatter {
  SdFormatter({required this.read, required this.command});
  final Future<String> Function(String path) read;
  final Future<void> Function(
    String executable,
    List<String> args,
    String? input,
  )
  command;
  static const disk = '/dev/mmcblk1';
  static const partition = '/dev/mmcblk1p1';

  Future<void> format({String? expectedCardId}) async {
    if ((await read('/sys/class/block/mmcblk1/device/type')).trim() != 'SD') {
      throw StateError('The removable SD card could not be identified');
    }
    final identity = (await read('/sys/class/block/mmcblk1/device/cid')).trim();
    if (identity.isEmpty) throw StateError('SD card identity is unavailable');
    if (expectedCardId != null &&
        identity.toLowerCase() != expectedCardId.toLowerCase()) {
      throw StateError('The selected SD card is no longer present');
    }
    final sectors = int.parse(
      (await read('/sys/class/block/mmcblk1/size')).trim(),
    );
    if (sectors < 32768) throw StateError('SD card capacity is invalid');
    final mounted = (await read('/proc/mounts'))
        .split('\n')
        .map((line) => line.split(' '))
        .where(
          (fields) =>
              fields.length > 1 &&
              RegExp(r'^/dev/mmcblk1(?:p\d+)?$').hasMatch(fields[0]),
        )
        .toList();
    if (mounted.any((fields) => fields[1] != '/mnt/sd')) {
      throw StateError(
        'SD card has mounts outside /mnt/sd; unmount them first',
      );
    }
    // A normal unmount MUST succeed before stopping the automount unit (whose
    // removal handler uses lazy unmount). Never format a lazily detached card.
    if (mounted.isNotEmpty) await command('/bin/umount', ['/mnt/sd'], null);
    await command('/usr/bin/systemctl', [
      'mask',
      '--runtime',
      'tempo-sdmount.service',
    ], null);
    try {
      await command('/usr/bin/systemctl', [
        'stop',
        'tempo-sdmount.service',
      ], null);
      if ((await read('/sys/class/block/mmcblk1/device/cid')).trim() !=
          identity) {
        throw StateError('SD card changed before formatting');
      }
      if ((await read('/proc/mounts'))
          .split('\n')
          .any((line) => RegExp(r'^/dev/mmcblk1(?:p\d+)? ').hasMatch(line))) {
        throw StateError('SD card is still mounted');
      }
      await command('/usr/sbin/sfdisk', [
        '--wipe',
        'always',
        disk,
      ], 'label: dos\nstart=2048, type=7\n');
      await command('/usr/bin/udevadm', ['settle'], null);
      if ((await read('/sys/class/block/mmcblk1/device/cid')).trim() !=
          identity) {
        throw StateError('SD card changed before creating its filesystem');
      }
      await command('/usr/sbin/mkfs.exfat', ['-L', 'TEMPO', partition], null);
      await command('/usr/sbin/fsck.exfat', ['-n', partition], null);
      await command('/bin/sync', [], null);
    } finally {
      await command('/usr/bin/systemctl', [
        'unmask',
        '--runtime',
        'tempo-sdmount.service',
      ], null);
      await command('/usr/bin/systemctl', [
        'start',
        'tempo-sdmount.service',
      ], null);
    }
  }
}

Future<String> readSdSystemFile(String path) => File(path).readAsString();

Future<void> runSdCommand(String exe, List<String> args, String? input) async {
  final process = await Process.start(exe, args);
  final output = process.stdout.drain<void>();
  final errors = process.stderr
      .transform(const SystemEncoding().decoder)
      .join();
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final code = await process.exitCode;
  await output;
  final message = await errors;
  if (code != 0) throw StateError('$exe failed ($code): $message');
}

/// Shared nonblocking lock: formatting and eject cannot race each other.
Future<void> withSdMaintenance(Future<void> Function() action) async {
  final lock = await File(
    '/run/tempo-format-sd.lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
    await action();
  } finally {
    await lock.close();
  }
}

Future<void> formatSdCard({String? expectedCardId}) => withSdMaintenance(
  () => SdFormatter(
    read: readSdSystemFile,
    command: runSdCommand,
  ).format(expectedCardId: expectedCardId),
);
