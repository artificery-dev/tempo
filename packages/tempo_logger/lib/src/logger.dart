import 'log_record.dart';
import 'log_writer.dart';

/// True delivers the record to the writer; false suppresses it.
typedef LogFilter = bool Function(LogRecord record);

bool acceptAllLogs(LogRecord record) => true;

final class Logger {
  const Logger({
    required this.tag,
    required this.writer,
    this.filter = acceptAllLogs,
    this.parent,
  });

  /// This logger's local tag segment.
  final String tag;
  final Logger? parent;

  /// Ancestors supply tag segments, not writers or filters.
  String get qualifiedTag =>
      parent == null ? tag : '${parent!.qualifiedTag}::$tag';
  final LogWriter writer;
  final LogFilter filter;

  /// Returns the constructed record, including when filtered out. Filter and
  /// writer failures propagate to the caller; no logging failures are hidden.
  Future<LogRecord> log(
    LogLevel level,
    String message, {
    Object? metadata,
  }) async {
    final record = LogRecord(
      tag: qualifiedTag,
      level: level,
      message: message,
      metadata: metadata,
    );
    if (filter(record)) await writer.write(record);
    return record;
  }

  Future<LogRecord> trace(String message, {Object? metadata}) =>
      log(LogLevel.trace, message, metadata: metadata);

  Future<LogRecord> debug(String message, {Object? metadata}) =>
      log(LogLevel.debug, message, metadata: metadata);

  Future<LogRecord> info(String message, {Object? metadata}) =>
      log(LogLevel.info, message, metadata: metadata);

  Future<LogRecord> warning(String message, {Object? metadata}) =>
      log(LogLevel.warning, message, metadata: metadata);

  Future<LogRecord> error(String message, {Object? metadata}) =>
      log(LogLevel.error, message, metadata: metadata);
}
