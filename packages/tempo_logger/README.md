# tempo_logger

A pure Dart structured logger. Filesystem access uses `package:file`; callers supply a local or in-memory file.

```dart
import 'package:tempo_logger/tempo_logger.dart';
import 'package:file/local.dart';

Future<void> main() async {
  final writer = MultiplexedLogWriter([
    ConsoleLogWriter(),
    FileLogWriter(const LocalFileSystem().file('tempo.jsonl')),
  ]);
  final project = Logger(tag: 'project', writer: writer);
  final decoder = Logger(
    tag: 'decoder',
    parent: project,
    writer: writer,
    filter: (record) => record.level.index >= LogLevel.info.index,
  );
  try {
    await decoder.info('Playback started', metadata: {
      'track': {'name': 'Middle C', 'sampleRate': 48000},
    }); // tag: project::decoder
  } finally {
    await writer.close();
  }
}
```

`trace`, `debug`, `info`, `warning`, and `error` take a message and optional
`Object? metadata`. Metadata accepts any JSON value: an object, list, string,
number, boolean, or null. Null (also the default) means no metadata. Records
snapshot and freeze nested collections, and reject non-JSON values. Include
errors and stack traces as strings inside metadata when needed.

Every record has a UTC timestamp, level, tag, and message. Methods return
`Future<LogRecord>` after delivery, or immediately after filtering.

Every logger has a required local tag and writer, an optional parent, and a
filter that accepts everything by default. Parent tags compose recursively with
`::`. The child's filter sees the fully qualified record; parents do not receive
or filter their children's records. Supply shared writers/filters explicitly.

Extend `LogWriter` to send records to memory, a network service, or another
consumer. `write`, `flush`, and `close` may return synchronously or asynchronously.
Formatting belongs to the writer: console output defaults to readable text,
file output defaults to JSONL, and both accept a `LogFormatter`. Files append by
default and require their parent directory to exist. Await `flush` or `close`
to detect file errors and finish buffered writes. Console close leaves stdout open.

Multiplexing passes the same record to every destination and waits for all of
them, even if one fails, then propagates the first error. Its `flush` and `close`
also apply to every destination, so it owns their lifecycle. Callers should await
logger methods and close writers after outstanding logging calls have finished.
The logger never silently swallows filter or writer failures.
