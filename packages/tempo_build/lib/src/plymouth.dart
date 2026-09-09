import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'process.dart';

/// Minimal bounded ELF reader for the ARM runtime dependency closure.
class ElfDependencies {
  ElfDependencies(this.bytes) {
    if (bytes.length < 16 ||
        bytes[0] != 0x7f ||
        ascii.decode(bytes.sublist(1, 4)) != 'ELF' ||
        ![1, 2].contains(bytes[4]) ||
        ![1, 2].contains(bytes[5]))
      throw const FormatException('Not a supported ELF file');
    view = ByteData.sublistView(bytes);
  }
  final Uint8List bytes;
  late final ByteData view;
  bool get is64 => bytes[4] == 2;
  Endian get endian => bytes[5] == 1 ? Endian.little : Endian.big;
  int u16(int offset) => view.getUint16(offset, endian);
  int u32(int offset) => view.getUint32(offset, endian);
  int word(int offset) => is64 ? view.getUint64(offset, endian) : u32(offset);
  Iterable<({int type, int offset, int address, int size})> get headers sync* {
    final start = word(is64 ? 0x20 : 0x1c);
    final step = u16(is64 ? 0x36 : 0x2a);
    final count = u16(is64 ? 0x38 : 0x2c);
    if (step < (is64 ? 56 : 32))
      throw const FormatException('Truncated ELF program header');
    for (var index = 0; index < count; index++) {
      final at = start + index * step;
      final offset = word(at + (is64 ? 8 : 4));
      final size = word(at + (is64 ? 32 : 16));
      if (offset > bytes.length || size > bytes.length - offset)
        throw const FormatException('ELF segment exceeds file');
      yield (
        type: u32(at),
        offset: offset,
        address: word(at + (is64 ? 16 : 8)),
        size: size,
      );
    }
  }

  String string(int offset, [int? end]) {
    final limit = end ?? bytes.length;
    if (offset < 0 || offset >= limit)
      throw const FormatException('Invalid ELF string offset');
    final terminator = bytes.indexOf(0, offset);
    if (terminator < 0 || terminator >= limit)
      throw const FormatException('Unterminated ELF string');
    return utf8.decode(bytes.sublist(offset, terminator));
  }

  String? get interpreter {
    for (final header in headers)
      if (header.type == 3)
        return string(header.offset, header.offset + header.size);
    return null;
  }

  List<String> get needed {
    final offsets = <int>[];
    int? table;
    for (final header in headers) {
      if (header.type != 2) continue;
      final step = is64 ? 16 : 8;
      for (
        var at = header.offset;
        at + step <= header.offset + header.size;
        at += step
      ) {
        final tag = word(at), value = word(at + step ~/ 2);
        if (tag == 0) break;
        if (tag == 1) offsets.add(value);
        if (tag == 5) table = value;
      }
    }
    if (offsets.isEmpty) return [];
    if (table == null) throw const FormatException('Missing ELF string table');
    for (final header in headers) {
      if (header.type == 1 &&
          table >= header.address &&
          table < header.address + header.size) {
        final base = header.offset + table - header.address;
        return offsets.map((offset) => string(base + offset)).toList();
      }
    }
    throw const FormatException('ELF string table is not mapped');
  }
}

Future<void> stagePlymouth(
  String tree,
  String output,
  CommandRunner runner,
) async {
  final libraries = <String>[];
  for (final directory in ['lib', 'usr/lib']) {
    final full = Directory(p.join(tree, directory));
    if (!full.existsSync()) continue;
    libraries.add(directory);
    final entries = full.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries)
      if (p.basename(entry.path).contains('-linux-') &&
          Directory(entry.path).existsSync())
        libraries.add(p.join(directory, p.basename(entry.path)));
  }
  String? plugins;
  for (final directory in [
    ...libraries.where((d) => d.startsWith('usr/lib')),
    ...libraries,
  ]) {
    if (Directory(p.join(tree, directory, 'plymouth')).existsSync()) {
      plugins = p.join(directory, 'plymouth');
      break;
    }
  }
  if (plugins == null)
    throw BuildFailure('Plymouth plugin directory is missing from $tree');
  final pending = [
    'usr/sbin/plymouthd',
    'usr/bin/plymouth',
    'etc/plymouth/plymouthd.conf',
    'usr/share/plymouth/plymouthd.defaults',
    for (final plugin in ['details.so', 'script.so', 'renderers/drm.so'])
      p.join(plugins, plugin),
  ];
  final staged = <String>{};
  while (pending.isNotEmpty) {
    final relative = pending.removeLast();
    if (!staged.add(relative)) continue;
    final file = File(p.join(tree, relative));
    if (!file.existsSync())
      throw BuildFailure('Missing Plymouth dependency: $relative');
    final bytes = file.readAsBytesSync();
    if (bytes.length < 4 ||
        bytes[0] != 0x7f ||
        bytes[1] != 69 ||
        bytes[2] != 76 ||
        bytes[3] != 70)
      continue;
    final elf = ElfDependencies(bytes);
    final interpreter = elf.interpreter;
    if (interpreter != null)
      pending.add(interpreter.replaceFirst(RegExp(r'^/+'), ''));
    for (final library in elf.needed) {
      final found = libraries
          .map((directory) => p.join(directory, library))
          .where((candidate) => File(p.join(tree, candidate)).existsSync())
          .firstOrNull;
      if (found == null)
        throw BuildFailure('Cannot resolve $library required by $relative');
      pending.add(found);
    }
  }
  var name = 'tempo';
  for (final line in File(
    p.join(tree, 'etc/plymouth/plymouthd.conf'),
  ).readAsLinesSync())
    if (line.trim().toLowerCase().startsWith('theme=')) {
      name = line.split('=').skip(1).join('=').trim();
      break;
    }
  if (name.contains('/') || name == '..')
    throw BuildFailure('Invalid Plymouth theme name');
  final theme = Directory(p.join(tree, 'usr/share/plymouth/themes', name));
  if (!theme.existsSync())
    throw BuildFailure('Configured Plymouth theme is missing: $name');
  for (final file in theme.listSync(recursive: true).whereType<File>())
    staged.add(p.relative(file.path, from: tree));
  final temporary = Directory('$output.stage-$pid')
    ..createSync(recursive: true);
  try {
    for (final relative in staged.toList()..sort()) {
      final target = p.join(temporary.path, relative);
      Directory(p.dirname(target)).createSync(recursive: true);
      // Dereference library links: retaining only a SONAME link without its
      // versioned target leaves a silently broken initramfs closure.
      await runner.run('cp', [
        '-L',
        '--preserve=mode,timestamps',
        p.join(tree, relative),
        target,
      ]);
    }
    if (Directory(output).existsSync())
      Directory(output).deleteSync(recursive: true);
    temporary.renameSync(output);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
  stdout.writeln('Staged ${staged.length} Plymouth files in $output');
}
