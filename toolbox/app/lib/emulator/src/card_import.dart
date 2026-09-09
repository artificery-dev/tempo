import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// Mobile document providers give files, not a persistent POSIX mount.
/// Copy selections into app storage so playback and scans keep stable paths.
Future<int> importCardFiles(List<XFile> files, Directory card) async {
  var copied = 0;
  for (final source in files) {
    final name = source.name.split(RegExp(r'[/\\]')).last;
    if (name.isEmpty || name == '.' || name == '..') {
      throw ArgumentError('The selected file has no usable name.');
    }
    final extension = name.split('.').last.toLowerCase();
    final folder =
        ['mp4', 'mkv', 'mov', 'webm', 'avi', 'm4v'].contains(extension)
        ? 'Movies'
        : 'Music';
    final directory = Directory('${card.path}/$folder');
    await directory.create(recursive: true);
    var target = File('${directory.path}/$name');
    var suffix = 1;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ending = dot > 0 ? name.substring(dot) : '';
    while (await target.exists()) {
      target = File('${directory.path}/$stem (${suffix++})$ending');
    }
    await source.saveTo(target.path);
    copied++;
  }
  return copied;
}
