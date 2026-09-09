import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:tempo_logger/tempo_logger.dart';

final toolboxLogsProvider = ChangeNotifierProvider<EmulatorEventLog>(
  (ref) => EmulatorEventLog(),
);

/// Bounded session history. UI and clipboard exports use the same entries.
class EmulatorEventLog extends ChangeNotifier implements LogWriter {
  EmulatorEventLog({this.capacity = 500}) : assert(capacity > 0);
  final int capacity;
  final _entries = ListQueue<LogRecord>();
  final _sources = SplayTreeSet<String>();
  List<String> get sources => List.unmodifiable(_sources);
  static String sourceOf(LogRecord record) => record.tag.split('::').first;
  List<LogRecord> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  String get text =>
      _entries.map((entry) => formatTextLogRecord(entry)).join('\n\n');
  String get jsonLines =>
      _entries.map((entry) => formatJsonLogRecord(entry)).join('\n');

  void clear() {
    _entries.clear();
    _sources.clear();
    notifyListeners();
  }

  @override
  void write(LogRecord entry) {
    if (_entries.length == capacity) _entries.removeFirst();
    _entries.add(entry);
    _sources.add(sourceOf(entry));
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_notificationQueued) {
        _notificationQueued = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _notificationQueued = false;
          if (!_disposed) notifyListeners();
        });
      }
    } else {
      notifyListeners();
    }
  }

  bool _notificationQueued = false;
  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void flush() {}

  @override
  void close() {}
}
