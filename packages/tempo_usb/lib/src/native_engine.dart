import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef EngineEvent = Map<String, dynamic>;

/// One helper process per operation; stdout is JSON-lines, stderr is diagnostic.
/// The Rust engine owns chip checks, partition policy, checksums and read-back.
class NativeUsbEngine {
  NativeUsbEngine({
    this.executable,
    this.agent,
    this.cancellationGrace = const Duration(seconds: 30),
    this.terminationGrace = const Duration(seconds: 2),
    this.drainGrace = const Duration(seconds: 2),
    Future<Process> Function(String, List<String>)? startProcess,
  }) : _startProcess = startProcess ?? Process.start;
  String? executable;
  String? agent;
  final Duration cancellationGrace;
  final Duration terminationGrace;
  final Duration drainGrace;
  final Future<Process> Function(String, List<String>) _startProcess;
  _NativeOperation? _operation;

  Future<EngineEvent> initialize() async {
    final name = Platform.isWindows ? 'tempo-usb.exe' : 'tempo-usb';
    executable ??= await _first([
      ?Platform.environment['TEMPO_USB_ENGINE'],
      '${File(Platform.resolvedExecutable).parent.path}/$name',
      '${Directory.current.path}/build/toolbox/rust/release/$name',
    ]);
    agent ??= await _first([
      ?Platform.environment['TEMPO_USB_AGENT'],
      if (executable != null) '${File(executable!).parent.path}/DA.img',
      // A macOS bundle keeps data out of Contents/MacOS, beside it instead.
      if (executable != null)
        '${File(executable!).parent.parent.path}/Resources/DA.img',
      '${Directory.current.path}/platform/firmware/DA.img',
    ]);
    return {
      'supported': executable != null && agent != null,
      'engine_available': executable != null,
      'agent_available': agent != null,
      'message': executable == null
          ? 'Install the Toolbox bundle containing tempo-usb, or set TEMPO_USB_ENGINE.'
          : agent == null
          ? 'Install the Toolbox DA.img resource, or set TEMPO_USB_AGENT.'
          : 'Rust USB engine ready.',
    };
  }

  static Future<String?> _first(List<String> paths) async {
    for (final path in paths) {
      if (await File(path).exists()) return File(path).absolute.path;
    }
    return null;
  }

  Future<EngineEvent> run(
    List<String> arguments, {
    required void Function(EngineEvent) onEvent,
  }) async {
    if (_operation != null)
      throw StateError('An operation is already running.');
    if (executable == null) throw StateError('USB engine is unavailable.');
    final operation = _operation = _NativeOperation();
    Process? process;
    var exited = false;
    final errors = StringBuffer();
    EngineEvent? terminal;
    Object? failure;
    StackTrace? failureStack;
    StreamSubscription<String>? stdoutSubscription;
    StreamSubscription<String>? stderrSubscription;
    final stdoutDone = Completer<void>(), stderrDone = Completer<void>();
    void protocolFailure(Object error, StackTrace stack) {
      failure ??= error;
      failureStack ??= stack;
      unawaited(_requestCancellation(operation).catchError((Object _) {}));
    }

    try {
      process = await _startProcess(executable!, arguments);
      // Always drain before publishing the process to a pending stop(). A child
      // can fill either pipe during startup or while unwinding cancellation.
      unawaited(process.stdin.done.then<void>((_) {}, onError: (Object _) {}));
      stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .listen(
            (text) {
              if (errors.length < 16384) {
                errors.write(
                  text.substring(
                    0,
                    text.length.clamp(0, 16384 - errors.length),
                  ),
                );
              }
            },
            onError: protocolFailure,
            onDone: stderrDone.complete,
          );
      stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (line.trim().isEmpty) return;
              try {
                final event = jsonDecode(line) as EngineEvent;
                if (const {
                  'result',
                  'error',
                  'firmware-info',
                  'raw-image-info',
                }.contains(event['event'])) {
                  terminal = event;
                } else if (!operation.cancelled) {
                  onEvent(event);
                }
              } catch (error, stack) {
                if (!operation.cancelled) protocolFailure(error, stack);
              }
            },
            onError: protocolFailure,
            onDone: stdoutDone.complete,
          );
      operation.started.complete(process);
      final code = await process.exitCode;
      exited = true;
      // A broken descendant can inherit an output pipe after the helper exits.
      // Keep draining throughout cleanup, but do not wait forever on that pipe.
      await Future.wait([
        stdoutDone.future,
        stderrDone.future,
      ]).timeout(drainGrace, onTimeout: () => <void>[]);
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      if (operation.cancelled) {
        return {
          'event': 'cancelled',
          if (terminal?['event'] == 'error' && terminal?['message'] != null)
            'message': terminal!['message'],
        };
      }
      if (code != 0 && terminal?['event'] != 'error') {
        terminal = {
          'event': 'error',
          'message': 'USB engine exited ($code). $errors',
        };
      }
      return terminal ??
          {
            'event': 'error',
            'message': 'USB engine exited without a result ($code). $errors',
          };
    } finally {
      if (!operation.started.isCompleted) operation.started.complete(process);
      if (process != null && !exited) {
        await _requestCancellation(operation);
        await process.exitCode;
      }
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
      if (process != null) {
        try {
          await process.stdin.close().timeout(terminationGrace);
        } catch (_) {
          // Exited helpers may already have closed their input pipe.
        }
      }
      if (identical(_operation, operation)) _operation = null;
      operation.done.complete();
    }
  }

  Future<void> _requestCancellation(_NativeOperation operation) {
    operation.cancelled = true;
    return operation.cancellation ??= _cancel(operation);
  }

  Future<void> _cancel(_NativeOperation operation) async {
    final process = await operation.started.future;
    if (process == null) return;
    try {
      // Windows Process.kill terminates instead of delivering SIGTERM. This
      // request lets Rust finish its bounded transfer and durable cleanup first.
      process.stdin.writeln('cancel');
      await process.stdin.flush().timeout(const Duration(seconds: 1));
    } catch (_) {
      // Old/broken helpers can close or ignore stdin; escalation remains bounded.
    }
    Future<bool> wait(Duration duration) async {
      try {
        await process.exitCode.timeout(duration);
        return true;
      } on TimeoutException {
        return false;
      }
    }

    if (await wait(cancellationGrace)) return;
    process.kill(ProcessSignal.sigterm);
    if (await wait(terminationGrace)) return;
    process.kill(ProcessSignal.sigkill);
    if (!await wait(terminationGrace)) {
      throw StateError(
        'USB helper did not exit after cancellation; it still owns the operation.',
      );
    }
  }

  Future<void> stop() async {
    final operation = _operation;
    if (operation == null) return;
    await _requestCancellation(operation);
    // Keep the slot occupied until both process cleanup and pipe draining finish.
    await operation.done.future;
  }
}

class _NativeOperation {
  final started = Completer<Process?>();
  final done = Completer<void>();
  bool cancelled = false;
  Future<void>? cancellation;
}
