import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Provision per-device credentials at first boot; images never contain tokens.
Future<void> initializeCredentials(String path, {String? group}) async {
  if (group != null && !RegExp(r'^[a-zA-Z0-9_-]+\$?$').hasMatch(group)) {
    throw const FormatException('Invalid credential group.');
  }
  final directory = Directory(path);
  await directory.create(recursive: true);
  Future<void> command(String name, List<String> args) async {
    final result = await Process.run(name, args);
    if (result.exitCode != 0) {
      throw FileSystemException('Credential permissions failed.', path);
    }
  }

  await command('chmod', ['750', directory.path]);
  if (group != null) await command('chgrp', [group, directory.path]);
  final lock = await File(
    '${directory.path}/.lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.blockingExclusive);
    final random = Random.secure();
    for (final name in ['api-token', 'owner-token']) {
      final file = File('${directory.path}/$name');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        final temporary = File('${file.path}.new');
        final value = base64UrlEncode(
          List.generate(32, (_) => random.nextInt(256)),
        );
        await temporary.writeAsString('$value\n', flush: true);
        await command('chmod', ['640', temporary.path]);
        if (group != null) await command('chgrp', [group, temporary.path]);
        await temporary.rename(file.path);
      } else if (type != FileSystemEntityType.file ||
          (await file.readAsString()).trim().isEmpty) {
        throw FileSystemException(
          'Existing credential is invalid; it was not replaced.',
          file.path,
        );
      }
      await command('chmod', ['640', file.path]);
      if (group != null) await command('chgrp', [group, file.path]);
    }
  } finally {
    await lock.unlock();
    await lock.close();
  }
}
