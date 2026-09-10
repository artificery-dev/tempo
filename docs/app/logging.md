# Logging

`tempo_logger` is a small pure Dart package: tagged loggers, immutable JSON
records, and pluggable writers. Toolbox is its consumer. The USB engine's
events and everything the emulator does are written as records into one
bounded session log, and the log drawer at the bottom of every Toolbox
section shows, filters and exports that log. On the device neither the player
nor the daemon uses the package. The player writes through Flutter's
`debugPrint`, the Dart daemon and the native broker write lines to standard
error, and systemd collects all of it in the journal, which is where
`journalctl` and the diagnostics capture read it.

## Components

| Where | What |
| --- | --- |
| `packages/tempo_logger/lib/src/logger.dart` | `Logger`, `LogFilter` and `acceptAllLogs`. |
| `packages/tempo_logger/lib/src/log_record.dart` | `LogRecord`, `LogLevel`, `LogFormatter`, `formatJsonLogRecord` and `formatTextLogRecord`. |
| `packages/tempo_logger/lib/src/log_writer.dart` | `LogWriter`, `ConsoleLogWriter` and `MultiplexedLogWriter`. |
| `packages/tempo_logger/lib/src/file_log_writer.dart` | `FileLogWriter`, JSONL appended through `package:file`. |
| `packages/tempo_logger/test/logger_test.dart` | The package's behaviour, over `MemoryFileSystem`. |
| `toolbox/app/lib/emulator/src/event_log.dart` | `EmulatorEventLog`, the `LogWriter` behind `toolboxLogsProvider`. |
| `toolbox/app/lib/emulator/src/event_log_panel.dart` | `EmulatorLogDock`, the drawer that shows the log. |
| `toolbox/app/lib/toolbox_controller.dart` | Turns USB engine events into records. |
| `toolbox/app/lib/emulator/emulator.dart` | The `emulator` logger and its per-source children. |
| `daemon/native/src/lib.rs` | The broker's `log!` macro, one `<section>: <message>` line on stderr. |
| `packages/toolbox_core/lib/live_device.dart` | The debug deploy, which redirects a hand-started player to `/tmp/tempo.log`. |
| `packages/tempo_build/lib/src/device_diagnostics.dart` | `collect-sysinfo`, including `journal.txt`. |

The package depends only on `package:file`, so callers supply a local or an
in-memory file, and it is a member of the pub workspace like the other
`packages/*`.

## Loggers and records

A `Logger` is constructed with a `tag`, a `writer`, an optional `filter` and
an optional `parent`. Parents contribute nothing but tag segments: the
qualified tag is the parent's qualified tag, `::`, the local tag, so a
logger named `decoder` under `project` writes records tagged
`project::decoder`. The filter sees the fully qualified record and returns
true to deliver it; parents never see or filter their children's records.
`trace`, `debug`, `info`, `warning` and `error` each build a record, apply
the filter, await the writer, and return the record whether or not it was
written. A filter or writer that throws propagates to the caller; nothing is
swallowed.

A `LogRecord` carries a UTC `timestamp`, a `level`, the `tag`, the `message`
and optional `metadata`. Metadata is snapshotted at construction: strings,
booleans, integers, finite doubles, null, lists and string-keyed maps are
copied into unmodifiable collections, and anything else, including `NaN`, is
an `ArgumentError`. Errors and stack traces therefore travel as strings inside
the metadata. `toJson` omits the `metadata` key when it is null.

```json
{"timestamp":"2026-01-01T12:00:00.000Z","level":"info","tag":"project::decoder","message":"Playback started","metadata":{"track":{"name":"Middle C"}}}
```

Two formatters are provided. `formatJsonLogRecord` is that one-line JSON.
`formatTextLogRecord` is `<timestamp> [<level>] <tag>: <message>`, followed
by the metadata pretty-printed on the next lines when there is any.

## Writers

`LogWriter` has `write`, `flush` and `close`; each may return synchronously
or a `Future`, and the defaults for `flush` and `close` do nothing.

| Writer | Behaviour |
| --- | --- |
| `ConsoleLogWriter` | Formats with the text formatter by default and hands the line to `print`, or to an `output` callback for a host console or a test. `close` leaves stdout open. |
| `FileLogWriter` | Opens the file lazily in append mode and writes one formatted line per record, JSON by default. Writes are queued so concurrent callers keep their order. The first failure is remembered and rethrown by every later `write`, `flush` and `close`; the parent directory must already exist. After `close`, writes fail with a `StateError`. |
| `MultiplexedLogWriter` | Delivers the same record to every destination, waits for all of them even when one fails, then throws the first error. Its `flush` and `close` apply to every destination, so it owns their lifecycle. |

Callers await the logger methods and close the writer after the last call,
which is how file errors surface.

## Toolbox

`toolboxLogsProvider` is a Riverpod provider holding one `EmulatorEventLog`,
a `ChangeNotifier` that is also a `LogWriter`. It keeps the most recent 500
records in a queue, tracks the set of sources, and exposes the entries as a
list, as text and as JSON lines. A record's source is the first `::` segment
of its tag. Notifications are deferred to a post-frame callback when a write
arrives during the build phase.

`ToolboxController` receives the log at construction. Every event from the
USB engine becomes a record tagged by the running task, `backup`, `restore`,
`flasher` or `device`, at `error` or `warning` level when the event kind says
so and `info` otherwise, with the message from the event and the whole event
map as metadata. The emulator builds a `Logger` tagged `emulator` over the
same writer and makes a child logger per source, so its records read
`emulator::<source>`; a stack trace, when one is supplied, is added to the
metadata as a string.

`EmulatorLogDock` is the drawer under every section, labelled `Logs (n)`. It
has a source dropdown that hides sources by unchecking them, a table of
timestamp, tag, level and message with the level coloured, rows that expand
to show the metadata, and three buttons: `Copy text`, `Copy JSONL` and `Clear
logs`. The copies use the two formatters over the visible entries, newest
first. The drawer and its place in the window are described in
[Emulator](../toolbox/emulator.md).

## On the device

The device has no `tempo_logger` writer. What each process prints, and where
it goes:

| Process | Writes | Read with |
| --- | --- | --- |
| The player under `tempo.service` | `debugPrint` lines, which flutter-pi prints to the process output. | `journalctl -u tempo.service` |
| `tempod` | `stderr.writeln` for its own messages, the `log:` callbacks of its services, `cadenced`'s forwarded output, and one JSON line per relocation event. | `journalctl -u tempod.service` |
| `tempod-native` | The `log!` macro, `<section>: <message>` on stderr. | `journalctl -u tempod-native.service` |

None of the units set `StandardOutput` or `StandardError`, so systemd's
default applies and both streams land in the journal under the unit's name.
`tempod` also prints `tempod listening at <url>` on stdout when its server is
bound.

A player started by hand through `toolbox dev app deploy` in debug mode is
not under a unit: `live_device.dart` launches it with `setsid` and redirects
both streams to `/tmp/tempo.log` on the device. `toolbox dev device
collect-sysinfo` saves the whole boot's journal as `journal.txt` with
`journalctl -b --no-pager -o short-precise`, next to the other captures.
The commands are in [Working with a device](../development/device.md).

```sh
toolbox dev device ssh journalctl -u tempod.service -b
toolbox dev device ssh journalctl -u tempo.service -f
toolbox dev device collect-sysinfo
```
