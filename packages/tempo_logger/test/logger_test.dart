import 'dart:async';
import 'dart:convert';
import 'package:file/file.dart';
import 'package:file/memory.dart';

import 'package:tempo_logger/tempo_logger.dart';
import 'package:test/test.dart';

class RecordingWriter extends LogWriter {
  final records = <LogRecord>[];
  bool flushed = false, closed = false;
  @override
  void write(LogRecord record) => records.add(record);
  @override
  void flush() => flushed = true;
  @override
  void close() => closed = true;
}

class FailingWriter extends LogWriter {
  @override
  void write(LogRecord record) => throw StateError('write failed');
}

class DelayedWriter extends LogWriter {
  final completed = Completer<void>();
  LogRecord? record;
  @override
  Future<void> write(LogRecord record) async {
    await completed.future;
    this.record = record;
  }
}

void main() {
  test('metadata accepts every JSON shape and null means omitted', () async {
    final writer = RecordingWriter();
    final logger = Logger(tag: 'test', writer: writer);
    for (final value in <Object?>[
      null,
      false,
      0,
      2.5,
      '',
      'text',
      [],
      [null, true],
      {},
      {
        'nested': [1],
      },
    ]) {
      final record = await logger.info('event', metadata: value);
      expect(record.metadata, value);
      expect(record.hasMetadata, value != null);
      expect(record.toJson().containsKey('metadata'), value != null);
      expect(jsonDecode(formatJsonLogRecord(record))['metadata'], value);
    }
    expect((await logger.info('omitted')).metadata, isNull);
  });

  test(
    'level methods deliver typed records and return the emitted record',
    () async {
      final writer = RecordingWriter();
      final logger = Logger(tag: 'player', writer: writer);
      final methods = [
        logger.trace,
        logger.debug,
        logger.info,
        logger.warning,
        logger.error,
      ];
      for (var i = 0; i < methods.length; i++) {
        final error = StateError('example');
        final stack = StackTrace.current;
        final record = await methods[i](
          'message',
          metadata: {
            'count': i,
            'ready': true,
            'error': error.toString(),
            'stackTrace': stack.toString(),
          },
        );
        expect(record, same(writer.records.last));
        expect(record.level, LogLevel.values[i]);
        expect(record.tag, 'player');
        expect(record.timestamp.isUtc, isTrue);
        expect((record.metadata as Map)['count'], i);
        expect((record.metadata as Map)['error'], error.toString());
        expect((record.metadata as Map)['stackTrace'], stack.toString());
      }
    },
  );

  test(
    'nested parents qualify tags before filtering without routing to parents',
    () async {
      final parentWriter = RecordingWriter();
      final childWriter = RecordingWriter();
      final parent = Logger(
        tag: 'project',
        writer: parentWriter,
        filter: (_) => false,
      );
      final child = Logger(
        tag: 'subsystem',
        parent: parent,
        writer: parentWriter,
      );
      LogRecord? filtered;
      final logger = Logger(
        tag: 'decoder',
        parent: child,
        writer: childWriter,
        filter: (record) {
          filtered = record;
          return record.level.index >= LogLevel.warning.index;
        },
      );
      final ignored = await logger.info('ignore');
      expect(filtered, same(ignored));
      expect(ignored.tag, 'project::subsystem::decoder');
      expect(childWriter.records, isEmpty);
      final written = await logger.warning('warning');
      expect(filtered, same(written));
      expect(childWriter.records.single, same(written));
      expect(parentWriter.records, isEmpty);
      expect(logger.tag, 'decoder');
    },
  );

  test('fields are immutable snapshots and JSON round-trips structure', () {
    final list = <Object?>[1, true, null];
    final fields = <String, Object?>{
      'nested': {'list': list},
    };
    final record = LogRecord(
      tag: 'test',
      level: LogLevel.trace,
      message: 'one\ntwo',
      metadata: fields,
    );
    list.clear();
    fields.clear();
    final restored = jsonDecode(formatJsonLogRecord(record)) as Map;
    expect(restored['metadata']['nested']['list'], [1, true, null]);
    expect(restored['message'], 'one\ntwo');
    expect(() => (record.metadata as Map)['new'] = 1, throwsUnsupportedError);
    expect(
      () =>
          (((record.metadata as Map)['nested'] as Map)['list'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => LogRecord(
        tag: 'test',
        level: LogLevel.info,
        message: '',
        metadata: {'bad': double.nan},
      ),
      throwsArgumentError,
    );
  });

  test('console writer owns formatting', () async {
    final output = <String>[];
    final logger = Logger(
      tag: 'test',
      writer: ConsoleLogWriter(
        output: output.add,
        formatter: (record) => '${record.tag}/${record.message}',
      ),
    );
    await logger.debug('hello');
    expect(output, ['test/hello']);
  });

  test(
    'multiplex delivers identical records and flushes/closes all destinations',
    () async {
      final a = RecordingWriter(), b = RecordingWriter();
      final writer = MultiplexedLogWriter([a, b]);
      final record = await Logger(tag: 'test', writer: writer).info('hello');
      expect(a.records.single, same(record));
      expect(b.records.single, same(record));
      await writer.flush();
      await writer.close();
      expect([a.flushed, b.flushed, a.closed, b.closed], everyElement(isTrue));
    },
  );

  test(
    'multiplex failure still delivers to and awaits remaining writers',
    () async {
      final delayed = DelayedWriter();
      final destination = RecordingWriter();
      final writer = MultiplexedLogWriter([
        FailingWriter(),
        delayed,
        destination,
      ]);
      var completed = false;
      final write = Logger(tag: 'test', writer: writer).error('problem');
      final expectation = expectLater(
        write.whenComplete(() => completed = true),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(destination.records.single.message, 'problem');
      expect(completed, isFalse);
      delayed.completed.complete();
      await expectation;
      expect(delayed.record, same(destination.records.single));
    },
  );

  test('filter exceptions propagate without writing', () async {
    final writer = RecordingWriter();
    final logger = Logger(
      tag: 'test',
      writer: writer,
      filter: (_) => throw StateError('filter failed'),
    );
    await expectLater(logger.info('hello'), throwsStateError);
    expect(writer.records, isEmpty);
  });

  test(
    'file writer appends JSONL, flushes and rejects writes after close',
    () async {
      final fs = MemoryFileSystem();
      final file = fs.file('/events.jsonl');
      await file.writeAsString('existing\n');
      final writer = FileLogWriter(file);
      final logger = Logger(tag: 'test', writer: writer);
      await logger.info(
        'first',
        metadata: {
          'nested': [1, 2],
        },
      );
      await logger.error(
        'second',
        metadata: {
          'error': StateError('oops').toString(),
          'stackTrace': 'trace',
        },
      );
      await writer.flush();
      final lines = await file.readAsLines();
      expect(lines.first, 'existing');
      expect(jsonDecode(lines[1])['metadata']['nested'], [1, 2]);
      expect(jsonDecode(lines[2])['metadata']['stackTrace'], 'trace');
      await writer.close();
      await writer.close();
      await expectLater(logger.info('closed'), throwsStateError);
    },
  );

  test(
    'file creation failures propagate from the in-memory filesystem',
    () async {
      final fs = MemoryFileSystem();
      final writer = FileLogWriter(fs.file('/missing/events.jsonl'));
      await expectLater(
        Logger(tag: 'test', writer: writer).info('fail'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(writer.flush(), throwsA(isA<FileSystemException>()));
      await expectLater(writer.close(), throwsA(isA<FileSystemException>()));
    },
  );

  test(
    'concurrent file writes preserve order and close waits for them',
    () async {
      final fs = MemoryFileSystem();
      final file = fs.file('/events.jsonl');
      final writer = FileLogWriter(file);
      final logger = Logger(tag: 'test', writer: writer);
      final writes = [
        for (var i = 0; i < 50; i++)
          logger.info('event', metadata: {'index': i}),
      ];
      await writer.close();
      await Future.wait(writes);
      expect(
        (await file.readAsLines()).map(
          (line) => jsonDecode(line)['metadata']['index'],
        ),
        List.generate(50, (i) => i),
      );
    },
  );
}
