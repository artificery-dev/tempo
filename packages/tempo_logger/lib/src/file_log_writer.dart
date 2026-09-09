import 'package:file/file.dart';

import 'log_record.dart';
import 'log_writer.dart';

/// Appends JSONL to the supplied filesystem's file. Writes are serialized even
/// when callers log concurrently. Parent directories must already exist.
final class FileLogWriter extends LogWriter {
  FileLogWriter(
    this.file, {
    this.formatter = formatJsonLogRecord,
    this.mode = FileMode.append,
  });
  final File file;
  final LogFormatter formatter;
  final FileMode mode;
  Future<RandomAccessFile>? _handle;
  Future<void> _pending = Future.value();
  Future<void>? _closing;
  Object? _failure;
  StackTrace? _failureStack;

  void _checkFailure() {
    if (_failure case final error?) {
      Error.throwWithStackTrace(error, _failureStack!);
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _failure ??= error;
        _failureStack ??= stack;
      },
    );
    return result;
  }

  Future<RandomAccessFile> _open() => _handle ??= file.open(mode: mode);

  @override
  Future<void> write(LogRecord record) {
    if (_closing != null)
      return Future.error(StateError('FileLogWriter is closed'));
    return _enqueue(() async {
      _checkFailure();
      final output = formatter(record);
      await (await _open()).writeString('$output\n');
    });
  }

  @override
  Future<void> flush() {
    if (_closing != null)
      return Future.error(StateError('FileLogWriter is closed'));
    return _enqueue(() async {
      _checkFailure();
      await (await _open()).flush();
    });
  }

  @override
  Future<void> close() => _closing ??= _enqueue(() async {
    try {
      if (_handle != null) await (await _handle!).close();
    } finally {
      _checkFailure();
    }
  });
}
