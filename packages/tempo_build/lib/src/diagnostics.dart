import 'dart:async';
import 'dart:io';
import 'package:toolbox_core/a2dp_capture.dart';
import 'package:toolbox_core/tone_analysis.dart';
import 'process.dart';

Future<int> diagnosticsCommand(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.writeln('$captureA2dpHelp\n$analyzeToneHelp');
    return 0;
  }
  final action = args.removeAt(0);
  if (action == 'analyze-tone') return runToneAnalysis(args);
  if (action != 'capture-a2dp')
    throw BuildFailure(
      'Unknown diagnostics action: $action\n$captureA2dpHelp\n$analyzeToneHelp',
      2,
    );
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(captureA2dpHelp);
    return 0;
  }
  if (args.length > 2) throw BuildFailure(captureA2dpHelp, 2);
  final peer = args.firstOrNull ?? '00:00:46:65:82:01';
  if (!RegExp(r'^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$').hasMatch(peer))
    throw BuildFailure('Invalid Bluetooth address: $peer', 2);
  final capture = A2dpCapture();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  if (!Platform.isWindows)
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
      subscriptions.add(
        signal.watch().listen((_) => unawaited(capture.cancel())),
      );
  try {
    return await capture.run(
      peer: peer,
      outputDirectory: args.length > 1 ? args[1] : 'build/btdiag',
    );
  } finally {
    await capture.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}
