import 'dart:io';
import 'package:tempo_data/tempo_data.dart';

typedef ProfileCommand =
    Future<ProcessResult> Function(String command, List<String> arguments);
Future<ProcessResult> _run(String command, List<String> arguments) =>
    Process.run(command, arguments).timeout(const Duration(seconds: 5));

/// Called while all profile consumers are stopped. Only these two roots are
/// inventoried; media folders and the device-local selector are never traversed.
Future<void> ensureProfileAccess(
  TempoProfilePaths paths,
  String user, {
  ProfileCommand command = _run,
}) async {
  if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_-]*\$?$').hasMatch(user)) {
    throw const FormatException('Invalid profile account.');
  }
  final dirs = <String>[], files = <String>[];
  for (final root in {paths.data, paths.config}) {
    final directory = Directory(root);
    // Refuse links in the root or its ancestors, including a linked .config.
    var ancestor = directory.absolute;
    while (ancestor.path != ancestor.parent.path) {
      if (await FileSystemEntity.type(ancestor.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException('Profile path contains a symlink', root);
      }
      ancestor = ancestor.parent;
    }
    await directory.create(recursive: true);
    dirs.add(directory.path);
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is Link) {
        throw FileSystemException('Profile contains a symlink', entry.path);
      }
      if (entry is Directory) {
        dirs.add(entry.path);
      } else if (entry is File) {
        files.add(entry.path);
      } else {
        throw FileSystemException('Unsupported profile entry', entry.path);
      }
    }
  }
  // Membership was validated before any changes. chown never dereferences a
  // symlink. Consumers stay stopped through permission changes and verification.
  for (final group in [
    (dirs.toSet().toList(), '0700'),
    (files.toSet().toList(), '0600'),
  ]) {
    for (var offset = 0; offset < group.$1.length; offset += 64) {
      final end = (offset + 64).clamp(0, group.$1.length);
      final batch = group.$1.sublist(offset, end);
      for (final path in batch) {
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw FileSystemException(
            'Profile changed during permission setup',
            path,
          );
        }
      }
      await command('chown', ['--no-dereference', user, '--', ...batch]);
      await command('chmod', [group.$2, '--', ...batch]);
    }
  }
  // FAT/exFAT may reject chown/chmod but provide correct access through mount
  // uid/masks. Judge usability as the configured frontend account, not as root.
  for (final root in {paths.data, paths.config}) {
    for (final permission in ['-r', '-w', '-x']) {
      final result = await command('runuser', [
        '-u',
        user,
        '--',
        'test',
        permission,
        root,
      ]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Frontend cannot access selected profile',
          root,
        );
      }
    }
    final result = await command('runuser', [
      '-u',
      user,
      '--',
      'find',
      '-P',
      root,
      '(',
      '!',
      '-readable',
      '-o',
      '!',
      '-writable',
      ')',
      '-print',
      '-quit',
    ]);
    if (result.exitCode != 0 || result.stdout.toString().trim().isNotEmpty) {
      throw FileSystemException(
        'Profile files are not readable and writable by frontend',
        root,
      );
    }
  }
}
