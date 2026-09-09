import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tempod.dart';

/// Where the sound goes.
enum OutputKind { speaker, headphones, bluetooth }

/// The output the player is heard on: the speaker, the jack, or a
/// Bluetooth device by name.
@immutable
class AudioOutput {
  const AudioOutput(this.kind, {this.name, this.id});

  final OutputKind kind;

  /// A Bluetooth device's name; null for the built-in outputs.
  final String? name;

  /// Stable PipeWire node name for a Bluetooth sink.
  final String? id;

  static const speaker = AudioOutput(OutputKind.speaker);
  static const headphones = AudioOutput(OutputKind.headphones);

  /// What to call it on screen.
  String get label => switch (kind) {
    OutputKind.speaker => 'Speaker',
    OutputKind.headphones => 'Headphones',
    OutputKind.bluetooth => name ?? 'Bluetooth',
  };

  @override
  bool operator ==(Object other) =>
      other is AudioOutput &&
      other.kind == kind &&
      other.name == name &&
      other.id == id;

  @override
  int get hashCode => Object.hash(kind, name, id);

  @override
  String toString() => 'AudioOutput($label)';
}

/// The output as the UI sees it. The value follows the jack (and, later,
/// the Bluetooth link); the switching itself is the sound server's.
abstract class OutputService implements ValueListenable<AudioOutput> {
  ValueNotifier<String> get onNewDevice;
  Stream<AudioOutput> get arrivals;
  Future<void> select(AudioOutput output);
}

/// An output that is only a value: for the emulator's rig and for tests.
class OutputSwitch extends ValueNotifier<AudioOutput> implements OutputService {
  OutputSwitch({AudioOutput output = AudioOutput.speaker}) : super(output);
  @override
  final onNewDevice = ValueNotifier('switch');
  final _arrivals = StreamController<AudioOutput>.broadcast();
  @override
  Stream<AudioOutput> get arrivals => _arrivals.stream;
  void detect(AudioOutput output) => _arrivals.add(output);
  @override
  Future<void> select(AudioOutput output) async {
    value = output;
  }

  @override
  void dispose() {
    _arrivals.close();
    onNewDevice.dispose();
    super.dispose();
  }
}

/// The device's output, through tempod's `output` op: the jack, asked
/// twice a second while anyone is listening. Two polls a second is what
/// makes a plug-in show on screen while the hand is still on the plug,
/// and it is one small line over the socket.
class DeviceOutput extends ValueNotifier<AudioOutput> implements OutputService {
  DeviceOutput({
    Tempod? tempod,
    this.period = const Duration(milliseconds: 500),
  }) : _tempod = tempod ?? Tempod(),
       super(AudioOutput.speaker);

  final Tempod _tempod;
  @override
  final onNewDevice = ValueNotifier('switch');
  final _arrivals = StreamController<AudioOutput>.broadcast();
  @override
  Stream<AudioOutput> get arrivals => _arrivals.stream;
  Set<String>? _sinks;
  bool? _jack;

  @override
  Future<void> select(AudioOutput output) async {
    if (output.kind == OutputKind.bluetooth && output.id == null) {
      throw ArgumentError('Bluetooth output requires a sink identity');
    }
    final reply = await _tempod.request({
      'op': 'output',
      'target': switch (output.kind) {
        OutputKind.speaker => 'speaker',
        OutputKind.headphones => 'headphones',
        OutputKind.bluetooth => output.id,
      },
    });
    if (reply['ok'] != true) {
      throw StateError('${reply['error'] ?? 'Cannot switch audio output'}');
    }
    await read();
  }

  final Duration period;
  Timer? _timer;
  bool _busy = false;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_timer == null && _tempod.available) {
      unawaited(read());
      _timer = Timer.periodic(period, (_) => read());
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _arrivals.close();
    onNewDevice.dispose();
    super.dispose();
  }

  /// Ask once. A reply that cannot be had leaves the value alone.
  Future<void> read() async {
    if (_busy) return;
    _busy = true;
    try {
      final reply = await _tempod.request({'op': 'output'});
      if (reply['ready'] == false || reply['ok'] == false) return;
      final sinks = <String, AudioOutput>{
        for (final item in (reply['sinks'] as List? ?? []))
          if (item is Map && item['id'] is String)
            item['id'] as String: AudioOutput(
              OutputKind.bluetooth,
              id: item['id'] as String,
              name: item['name'] as String?,
            ),
      };
      final jack = reply['jack'] as bool?;
      // First snapshot establishes a baseline, never an arrival prompt.
      if (_sinks != null) {
        for (final id in sinks.keys.toSet().difference(_sinks!)) {
          _arrivals.add(sinks[id]!);
        }
      }
      if (_jack != null && jack != null && jack != _jack) {
        _arrivals.add(jack ? AudioOutput.headphones : AudioOutput.speaker);
      }
      _sinks = sinks.keys.toSet();
      _jack = jack;
      value = switch (reply['output']) {
        'headphones' => AudioOutput.headphones,
        'speaker' => AudioOutput.speaker,
        'bluetooth' => AudioOutput(
          OutputKind.bluetooth,
          name: reply['name'] as String?,
        ),
        _ => value,
      };
    } on Object {
      // No daemon, or no jack device: the value stays.
    } finally {
      _busy = false;
    }
  }
}
