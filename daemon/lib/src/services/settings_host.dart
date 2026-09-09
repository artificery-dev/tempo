import 'dart:convert';
import 'dart:async';
import 'dart:io';

/// Serializes persistent settings independently of the frontend lifetime.
final class SettingsHost {
  SettingsHost(String path) : file = File(path);
  final File file;
  final _changes = StreamController<Map<String, Object?>>.broadcast(sync: true);
  Stream<Map<String, Object?>> get changes => _changes.stream;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  Future<Map<String, Object?>> read() async {
    await _tail;
    if (!await file.exists()) return {};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Stored settings are not an object.');
    }
    return decoded;
  }

  Future<void> write(Map<String, Object?> values) {
    if (_closed) throw StateError('Settings service is closed.');
    final keys = values.keys.toList()..sort();
    // Encode before queueing so caller mutation cannot change an accepted write.
    final encoded = const JsonEncoder.withIndent(
      '  ',
    ).convert({for (final key in keys) key: values[key]});
    if (utf8.encode(encoded).length > 64 * 1024) {
      throw const FormatException('Settings exceed size limit.');
    }
    final result = _tail.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp.$pid');
      try {
        await temporary.writeAsString(encoded, flush: true);
        await temporary.rename(file.path);
        _changes.add(jsonDecode(encoded) as Map<String, Object?>);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
    // One failed write must not poison later requests or graceful shutdown.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> close() async {
    _closed = true;
    await _tail;
    await _changes.close();
  }
}
