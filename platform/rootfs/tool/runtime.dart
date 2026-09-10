import 'sd_formatter.dart';
import 'sd_ejector.dart';
import 'dart:ffi';
import 'dart:io';

const mount = '/mnt/sd';
const card = '/dev/mmcblk1p1';
const profileUid = int.fromEnvironment('TEMPO_UID', defaultValue: 1000);
const profileGid = int.fromEnvironment('TEMPO_GID', defaultValue: 1000);

Future<bool> run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) stderr.write(result.stderr);
  return result.exitCode == 0;
}

Future<bool> mounted(String path) async =>
    (await Process.run('mountpoint', ['-q', path])).exitCode == 0;

Future<void> clearFlag(String directory) async {
  final flag = File('$directory/FORCE_REINSTALL');
  if (await FileSystemEntity.type(flag.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    await flag.delete();
  }
  if (!await run('sync', [])) throw StateError('Could not sync the card');
}

Future<void> clearReinstallFlag() async {
  if (await mounted(mount)) {
    await clearFlag(mount);
    return;
  }
  // No card is normal. The service must retry when one becomes available.
  if (!File(card).existsSync())
    throw StateError('No microSD partition available');
  final temporary = await Directory.systemTemp.createTemp('tempo-sd-');
  var isMounted = false;
  try {
    for (final fs in ['vfat', 'exfat', 'ext4', 'ext2']) {
      if (await run('mount', ['-t', fs, card, temporary.path])) {
        isMounted = true;
        break;
      }
    }
    if (!isMounted) throw StateError('Cannot mount the microSD partition');
    await clearFlag(temporary.path);
  } finally {
    if (isMounted && !await run('umount', [temporary.path])) {
      throw StateError('Cannot unmount ${temporary.path}; mount retained');
    }
    // Never recursively remove a directory which could still be a mount.
    await temporary.delete();
  }
}

Future<void> main(List<String> args) async {
  if (args.length == 2 &&
      args.first == 'format-sd' &&
      RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(args[1])) {
    try {
      await formatSdCard(expectedCardId: args[1]);
    } catch (error) {
      stderr.writeln('tempo-system: $error');
      exitCode = 1;
    }
    return;
  }
  if (args.length == 2 &&
      args.first == 'eject-sd' &&
      RegExp(r'^[0-9]+$').hasMatch(args[1])) {
    try {
      await ejectSdCard(expectedMountId: args[1]);
    } catch (error) {
      stderr.writeln('tempo-system: $error');
      exitCode = 1;
    }
    return;
  }
  if (args.length != 1 ||
      ![
        'launch',
        'sdmount',
        'clear-reinstall-flag',
        'format-sd',
        'eject-sd',
      ].contains(args.single)) {
    stdout.writeln(
      'tempo-system launch|sdmount|clear-reinstall-flag|format-sd|eject-sd',
    );
    exitCode = args.length == 1 && args.single == '--help' ? 0 : 2;
    return;
  }
  try {
    switch (args.single) {
      case 'launch':
        final library = DynamicLibrary.open(
          '${File(Platform.resolvedExecutable).parent.path}/tempo-system.so',
        );
        final held = library.lookupFunction<Int32 Function(), int Function()>(
          'tempo_volume_keys_held',
        )();
        if (held != 0)
          stderr.writeln(
            'tempo: both volume keys held - debug mode (attach on :41200)',
          );
        exitCode = library
            .lookupFunction<Int32 Function(Int32), int Function(int)>(
              'tempo_launch',
            )(held);
      case 'sdmount':
        await Directory(mount).create(recursive: true);
        final type = (await Process.run('/usr/sbin/blkid', [
          '-s',
          'TYPE',
          '-o',
          'value',
          card,
        ])).stdout.toString().trim();
        final options = [
          'sync',
          'noatime',
          if (type == 'vfat' || type == 'exfat') ...[
            'uid=$profileUid',
            'gid=$profileGid',
            'fmask=0177',
            'dmask=0077',
          ],
        ].join(',');
        if (!await mounted(mount) &&
            !await run('mount', ['-o', options, card, mount])) {
          throw StateError('Cannot mount the microSD partition');
        }
      case 'eject-sd':
        await ejectSdCard();
      case 'format-sd':
        await formatSdCard();
      case 'clear-reinstall-flag':
        await clearReinstallFlag();
    }
  } on Object catch (error) {
    stderr.writeln('tempo-system: $error');
    exitCode = 1;
  }
}
