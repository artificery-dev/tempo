import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Notify from the daemon PID itself, so systemd can reject notifications from
/// subprocesses such as bluetoothctl which inherit NOTIFY_SOCKET.
void notifySystemdReady() => notifySystemd('READY=1');

void notifySystemd(String value) {
  if ((Platform.environment['NOTIFY_SOCKET'] ?? '').isEmpty) return;
  final library = DynamicLibrary.open('libsystemd.so.0');
  final notify = library
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('sd_notify');
  final message = value.toNativeUtf8();
  try {
    final result = notify(0, message);
    if (result <= 0) {
      throw StateError('Systemd readiness notification failed ($result)');
    }
  } finally {
    calloc.free(message);
  }
}

/// A fixed startup budget, not an indefinitely renewed watchdog. Send the full
/// allowance immediately because synchronous file hashing can block timers.
final class ProfileStartupDeadline {
  ProfileStartupDeadline({
    this.budget = const Duration(minutes: 10),
    this.interval = const Duration(seconds: 5),
    void Function(String)? notify,
  }) : _notify = notify ?? notifySystemd;
  final Duration budget, interval;
  final void Function(String) _notify;
  final _clock = Stopwatch();
  Timer? _timer;
  void start() {
    if (_clock.isRunning || _timer != null) {
      throw StateError('Startup budget already started');
    }
    _clock.start();
    _extend();
    _timer = Timer.periodic(interval, (_) => _extend());
  }

  void _extend() {
    final remaining = budget - _clock.elapsed;
    if (remaining <= Duration.zero) {
      _timer?.cancel();
      _notify('EXTEND_TIMEOUT_USEC=1');
      return;
    }
    _notify('EXTEND_TIMEOUT_USEC=${remaining.inMicroseconds}');
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }
}
