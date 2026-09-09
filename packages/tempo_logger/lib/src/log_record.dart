import 'dart:convert';

enum LogLevel { trace, debug, info, warning, error }

/// A structured event with optional, immutable JSON metadata.
final class LogRecord {
  LogRecord({
    required this.tag,
    required this.level,
    required this.message,
    DateTime? timestamp,
    Object? metadata,
  }) : timestamp = (timestamp ?? DateTime.now()).toUtc(),
       metadata = _snapshot(metadata);

  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  bool get hasMetadata => metadata != null;
  final Object? metadata;

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'tag': tag,
    'message': message,
    if (hasMetadata) 'metadata': metadata,
  };
}

Map<String, Object?> _snapshotMap(Map<Object?, Object?> fields) {
  final result = <String, Object?>{};
  for (final entry in fields.entries) {
    if (entry.key is! String) {
      throw ArgumentError.value(
        entry.key,
        'metadata',
        'JSON object keys must be strings',
      );
    }
    result[entry.key as String] = _snapshot(entry.value);
  }
  return Map.unmodifiable(result);
}

Object? _snapshot(Object? value) => switch (value) {
  null || String() || bool() || int() => value,
  double() when value.isFinite => value,
  Map<Object?, Object?>() => _snapshotMap(value),
  List<Object?>() => List<Object?>.unmodifiable(value.map(_snapshot)),
  _ => throw ArgumentError.value(
    value,
    'metadata',
    'Expected JSON-compatible values',
  ),
};

typedef LogFormatter = String Function(LogRecord record);

String formatJsonLogRecord(LogRecord record) => jsonEncode(record.toJson());

String formatTextLogRecord(LogRecord record) =>
    '${record.timestamp.toIso8601String()} [${record.level.name}] ${record.tag}: ${record.message}'
    '${record.hasMetadata ? '\n${const JsonEncoder.withIndent('  ').convert(record.metadata)}' : ''}';
