import 'sd_formatter.dart';

/// The hardware half of eject. Call only after media owners have quiesced and
/// playback handles are closed. Never use lazy/forced unmount for user eject.
class SdEjector {
  SdEjector({required this.read, required this.command});
  final Future<String> Function(String path) read;
  final Future<void> Function(String, List<String>, String?) command;

  Future<void> eject({String? expectedMountId}) async {
    Future<void> checkMount() async {
      if (expectedMountId == null) return;
      final rows = (await read('/proc/self/mountinfo'))
          .split('\n')
          .map((line) => line.split(' '))
          .where((row) => row.length > 4 && row[4] == '/mnt/sd');
      if (rows.length != 1 || rows.single[0] != expectedMountId) {
        throw StateError('SD mount changed before unmount');
      }
    }

    await checkMount();
    final rows = (await read('/proc/mounts'))
        .split('\n')
        .map((line) => line.split(' '))
        .where((fields) => fields.length > 1)
        .toList();
    final cards = rows.where(
      (fields) => RegExp(r'^/dev/mmcblk1(?:p\d+)?$').hasMatch(fields[0]),
    );
    if (cards.any((fields) => fields[1] != '/mnt/sd')) {
      throw StateError('SD card has other mounts; unmount them first');
    }
    final targets = rows.where((fields) => fields[1] == '/mnt/sd');
    if (targets.any((fields) => !cards.contains(fields))) {
      throw StateError('/mnt/sd does not contain the removable SD card');
    }
    if (targets.isEmpty) return; // Already unmounted: safe to retry.
    if ((await read('/sys/class/block/mmcblk1/device/type')).trim() != 'SD') {
      throw StateError('The removable SD card could not be identified');
    }
    // Report filesystem writeback errors before unmounting. A normal umount
    // also drains filesystem work and refuses any still-open media handles.
    await command('/bin/sync', ['-f', '/mnt/sd'], null);
    await checkMount();
    await command('/bin/umount', ['/mnt/sd'], null);
    // The unit's ExecStop uses lazy unmount for surprise removal. It must run
    // only AFTER the normal unmount succeeded, never as a fallback for EBUSY.
    await command('/usr/bin/systemctl', [
      'stop',
      'tempo-sdmount.service',
    ], null);
  }
}

Future<void> ejectSdCard({String? expectedMountId}) => withSdMaintenance(
  () => SdEjector(
    read: readSdSystemFile,
    command: runSdCommand,
  ).eject(expectedMountId: expectedMountId),
);
