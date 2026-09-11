import 'dart:async';
import 'dart:io';

class BuildFailure implements Exception {
  BuildFailure(this.message, [this.code = 1]);
  final String message;
  final int code;
  @override
  String toString() => message;
}

/// What the `dart` running this tool tells its children about itself, and
/// what a child of another SDK must not hear. Dart 3.13's `dart run` exports
/// `DART_ROOT`; a pinned Flutter SDK's own `dart test` then takes that as
/// its SDK, finds no Flutter around it, and re-resolves the workspace with
/// plain pub, which refuses the Flutter packages.
const _ownSdkVariables = ['DART_ROOT', 'DASH__TOOL'];

/// The environment a child gets: the parent's without the variables above,
/// then [extra] on top.
Map<String, String> childEnvironment(
  Map<String, String> parent, [
  Map<String, String>? extra,
]) => {
  for (final entry in parent.entries)
    if (!_ownSdkVariables.contains(entry.key)) entry.key: entry.value,
  ...?extra,
};

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
      environment: childEnvironment(Platform.environment, environment),
      includeParentEnvironment: false,
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
      environment: childEnvironment(Platform.environment, environment),
      includeParentEnvironment: false,
    );
    if (check && result.exitCode != 0) {
      throw BuildFailure('$executable: ${result.stderr}', result.exitCode);
    }
    return result;
  }
}

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
