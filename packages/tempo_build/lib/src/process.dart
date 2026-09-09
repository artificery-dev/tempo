import 'dart:async';
import 'dart:io';

class BuildFailure implements Exception {
  BuildFailure(this.message, [this.code = 1]);
  final String message;
  final int code;
  @override
  String toString() => message;
}

/// Arguments always cross the host process boundary as individual values.
/// Interactive children inherit stdin; noninteractive input is streamed.
class CommandRunner {
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Stream<List<int>>? input,
    bool check = true,
  }) async {
    final child = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: input == null
          ? ProcessStartMode.inheritStdio
          : ProcessStartMode.normal,
    );
    final signals = <StreamSubscription<ProcessSignal>>[];
    if (!Platform.isWindows) {
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
        signals.add(signal.watch().listen((_) => child.kill(signal)));
      }
    }
    try {
      if (input != null) {
        final outputs = [
          stdout.addStream(child.stdout),
          stderr.addStream(child.stderr),
        ];
        try {
          await child.stdin.addStream(input);
        } on IOException {
          /* Exit status explains early closure. */
        }
        await child.stdin.close();
        await Future.wait(outputs);
      }
      final code = await child.exitCode;
      if (check && code != 0)
        throw BuildFailure(
          '$executable failed (exit $code)',
          code < 0 ? 128 - code : code,
        );
      return code;
    } finally {
      for (final signal in signals) {
        await signal.cancel();
      }
    }
  }

  Future<ProcessResult> capture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool check = true,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    if (check && result.exitCode != 0) {
      throw BuildFailure('$executable: ${result.stderr}', result.exitCode);
    }
    return result;
  }
}

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
