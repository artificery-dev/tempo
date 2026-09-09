import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

const captureA2dpHelp =
    '''Usage: toolbox dev diagnostics capture-a2dp [BLUETOOTH_ADDRESS] [OUTPUT_DIRECTORY]

Route an incoming PipeWire/BlueZ A2DP stream to a silent null sink and record
its monitor as timestamped PCM. Default peer: 00:00:46:65:82:01.
Default output directory: build/btdiag.
The peer must already be connected as an A2DP source. Stop with Ctrl-C.
Requires pactl and pw-record on the capture host; jq is no longer needed.''';

/// Injectable host process boundary; this does not connect to the player by SSH.
class CaptureCommands {
  final _active = <Process>{};
  bool _cancelled = false;
  Future<ProcessResult> capture(String executable, List<String> args) async {
    if (_cancelled) throw StateError('Capture cancelled');
    final child = await Process.start(executable, args);
    _active.add(child);
    if (_cancelled) child.kill(ProcessSignal.sigint);
    final output = child.stdout.transform(utf8.decoder).join(),
        error = child.stderr.transform(utf8.decoder).join();
    await child.stdin.close();
    try {
      final code = await child.exitCode.timeout(const Duration(seconds: 5));
      return ProcessResult(child.pid, code, await output, await error);
    } finally {
      _active.remove(child);
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    }
  }

  Future<int> record(List<String> args) async {
    if (_cancelled) return 130;
    final child = await Process.start(
      'pw-record',
      args,
      mode: ProcessStartMode.inheritStdio,
    );
    _active.add(child);
    if (_cancelled) child.kill(ProcessSignal.sigint);
    try {
      return await child.exitCode;
    } finally {
      _active.remove(child);
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    for (final child in _active.toList()) {
      child.kill(ProcessSignal.sigint);
      try {
        await child.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      }
    }
  }
}

/// Routes only the selected Bluetooth peer; the diagnostic sink is reusable.
class A2dpCapture {
  A2dpCapture({
    CaptureCommands? commands,
    void Function(String)? log,
    this.routePeriod = const Duration(milliseconds: 250),
    DateTime Function()? now,
  }) : commands = commands ?? CaptureCommands(),
       log = log ?? stderr.writeln,
       now = now ?? DateTime.now;
  final CaptureCommands commands;
  final void Function(String) log;
  final Duration routePeriod;
  final DateTime Function() now;
  final _stop = Completer<void>();
  bool _used = false;
  Future<void> cancel() async {
    if (!_stop.isCompleted) _stop.complete();
    await commands.cancel();
  }

  Future<int> run({
    String peer = '00:00:46:65:82:01',
    String outputDirectory = 'build/btdiag',
  }) async {
    if (_used) throw StateError('A capture session can only run once.');
    _used = true;
    if (!RegExp(r'^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$').hasMatch(peer))
      throw ArgumentError('Invalid Bluetooth address: $peer');
    for (final executable in ['pactl', 'pw-record']) {
      try {
        await commands.capture(executable, ['--version']);
      } on ProcessException {
        throw StateError('Missing dependency: $executable');
      }
    }
    if (_stop.isCompleted) return 130;
    Directory(outputDirectory).createSync(recursive: true);
    Future<List<dynamic>> list(String type) async {
      final result = await commands.capture('pactl', [
        '--format=json',
        'list',
        type,
      ]);
      if (result.exitCode != 0)
        throw StateError('pactl list $type failed: ${result.stderr}');
      final decoded = jsonDecode(result.stdout as String);
      if (decoded is! List)
        throw const FormatException('Expected pactl JSON array');
      return decoded;
    }

    Object? sinkIndex(List<dynamic> sinks) => sinks
        .whereType<Map>()
        .where((sink) => sink['name'] == 'bt_diag')
        .firstOrNull?['index'];
    Object? index;
    try {
      index = sinkIndex(await list('sinks'));
    } catch (_) {
      /* Loading may establish the sink. */
    }
    if (index == null) {
      final loaded = await commands.capture('pactl', [
        'load-module',
        'module-null-sink',
        'sink_name=bt_diag',
        'sink_properties=device.description=BT_Diagnostic_Sink',
        'rate=48000',
        'channels=2',
        'channel_map=front-left,front-right',
      ]);
      if (loaded.exitCode != 0)
        throw StateError('Cannot create bt_diag sink: ${loaded.stderr}');
      log(
        'Created bt_diag (PulseAudio module ${(loaded.stdout as String).trim()}).',
      );
      index = sinkIndex(await list('sinks'));
    }
    if (index is! int || index < 0)
      throw StateError('Could not resolve the bt_diag sink index.');
    if (_stop.isCompleted) return 130;
    final stamp = now()
        .toUtc()
        .toIso8601String()
        .replaceAll('-', '')
        .replaceAll(':', '');
    final file = p.join(
      outputDirectory,
      'a2dp-${peer.replaceAll(':', '_')}-$stamp.wav',
    );
    final metadata = File('${file.substring(0, file.length - 4)}.meta');
    metadata.writeAsStringSync(
      'capture_started_at=${now().toUtc().toIso8601String()}\npeer_address=$peer\nsink_name=bt_diag\nsink_index=$index\nsample_rate=48000\nchannels=2\nsample_format=s16\n',
    );
    Future<void> route() async {
      while (!_stop.isCompleted) {
        try {
          for (final input in (await list('sink-inputs')).whereType<Map>()) {
            if (_stop.isCompleted) break;
            final properties = input['properties'];
            if (properties is! Map ||
                '${properties['api.bluez5.address'] ?? ''}'.toLowerCase() !=
                    peer.toLowerCase() ||
                input['sink'] == index ||
                input['index'] is! int)
              continue;
            final moved = await commands.capture('pactl', [
              'move-sink-input',
              '${input['index']}',
              'bt_diag',
            ]);
            if (moved.exitCode == 0)
              log(
                '${now().toUtc().toIso8601String()} moved sink input ${input['index']} to bt_diag',
              );
          }
        } catch (_) {
          /* A transient disappeared stream must not stop capture. */
        }
        await Future.any([Future<void>.delayed(routePeriod), _stop.future]);
      }
    }

    log(
      'Recording $peer through bt_diag (monitor target $index).\nPCM: $file\nMetadata: ${metadata.path}',
    );
    final routing = route();
    try {
      final code = await commands.record([
        '--target',
        '$index',
        '--rate',
        '48000',
        '--channels',
        '2',
        '--format',
        's16',
        file,
      ]);
      return code < 0 ? 128 - code : code;
    } finally {
      final stoppedAt = now().toUtc().toIso8601String();
      await cancel();
      await routing;
      metadata.writeAsStringSync(
        'capture_stopped_at=$stoppedAt\n',
        mode: FileMode.append,
      );
    }
  }
}
