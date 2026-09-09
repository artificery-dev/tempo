/// Desktop drag sources can repeat URI entries or provide a raw URI list.
/// Count distinct local paths, not transport entries. Portal keys are not paths.
List<String> firmwareDropPaths(Iterable<String> paths, {String? rawText}) {
  final result = <String>{};
  void add(String entry) {
    final value = entry.replaceAll('\u0000', '').trim();
    if (value.isEmpty || value.startsWith('#')) return;
    final uri = Uri.tryParse(value);
    final windowsPath = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value);
    if (uri != null && uri.scheme == 'file') {
      try {
        final windows =
            uri.pathSegments.isNotEmpty &&
            RegExp(r'^[a-zA-Z]:$').hasMatch(uri.pathSegments.first);
        result.add(uri.normalizePath().toFilePath(windows: windows));
      } on UnsupportedError {
        // A remote file URI is not a local firmware source.
      } on ArgumentError {
        // Ignore malformed URI entries.
      }
    } else if (windowsPath ||
        value.startsWith('/') ||
        value.startsWith(r'\\')) {
      result.add(value);
    }
  }

  for (final path in paths) {
    add(path);
  }
  // Only use the original transport payload if the plugin supplied no paths;
  // a resolved portal path and its original URI can name the same file.
  if (result.isEmpty && rawText != null) {
    for (final line in rawText.split(RegExp(r'[\r\n]+'))) {
      add(line);
    }
  }
  return result.toList();
}
