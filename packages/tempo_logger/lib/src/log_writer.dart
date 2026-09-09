import 'dart:async';

import 'log_record.dart';

/// Writers own formatting and delivery; implementations may be synchronous or
/// asynchronous. Callers await writes and flush/close before shutting down.
abstract class LogWriter {
  FutureOr<void> write(LogRecord record);
  FutureOr<void> flush() {}
  FutureOr<void> close() {}
}

/// Uses Dart's console on every platform. The output callback can be replaced
/// for a host's console or for tests. Closing does not close process stdout.
final class ConsoleLogWriter extends LogWriter {
  ConsoleLogWriter({
    this.formatter = formatTextLogRecord,
    void Function(String)? output,
  }) : _output = output ?? print;
  final LogFormatter formatter;
  final void Function(String) _output;

  @override
  void write(LogRecord record) => _output(formatter(record));
}

/// Sends the same record to every writer, even if another writer fails.
/// Operations wait for all destinations, then propagate the first error.
/// Closing this writer also closes its destinations; it owns their lifecycle.
final class MultiplexedLogWriter extends LogWriter {
  MultiplexedLogWriter(Iterable<LogWriter> writers)
    : writers = List.unmodifiable(writers);
  final List<LogWriter> writers;

  Future<void> _each(FutureOr<void> Function(LogWriter) operation) =>
      Future.wait(
        writers.map((writer) => Future<void>.sync(() => operation(writer))),
      );

  @override
  Future<void> write(LogRecord record) =>
      _each((writer) => writer.write(record));
  @override
  Future<void> flush() => _each((writer) => writer.flush());
  @override
  Future<void> close() => _each((writer) => writer.close());
}
