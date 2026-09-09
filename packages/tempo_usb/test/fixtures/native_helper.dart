import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args[0], marker = File(args[1]);
  if (mode == 'result') {
    stdout.writeln(jsonEncode({'event': 'result', 'clean': true}));
    return;
  }
  StreamSubscription<ProcessSignal>? signal;
  if (!Platform.isWindows) {
    signal = ProcessSignal.sigterm.watch().listen((_) {
      if (mode == 'legacy') {
        marker.writeAsStringSync('legacy cleanup', flush: true);
        exit(0);
      }
      // Broken helpers deliberately ignore Unix SIGTERM. A cooperative helper
      // also ignores it so a missing stdin request cannot accidentally pass.
    });
  }
  stdout.writeln(jsonEncode({'event': 'ready'}));
  if (mode == 'broken' || mode == 'legacy') {
    stdin.listen((_) {});
    await Completer<void>().future;
  }
  if (mode == 'malformed') stdout.writeln('not-json');
  final command = await stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((line) => line == 'cancel');
  // Fill both pipes beyond OS buffering. The parent must drain them while
  // waiting for cleanup, including cancellation during Process.start.
  final line = jsonEncode({'event': 'progress', 'padding': 'x' * 16384});
  for (var i = 0; i < 96; i++) {
    stdout.writeln(line);
    stderr.writeln('diagnostic' * 1638);
  }
  await Future.wait([stdout.flush(), stderr.flush()]);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await marker.writeAsString('$command cleanup complete', flush: true);
  stdout.writeln(
    jsonEncode(
      mode == 'cleanup-error'
          ? {
              'event': 'error',
              'message':
                  'Cancelled. The Y2 also could not be reset: DA read did not finish; reconnect or reset the player for recovery.',
            }
          : {'event': 'result'},
    ),
  );
  await stdout.flush();
  await signal?.cancel();
}
