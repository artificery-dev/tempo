import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

import 'emulator_window.dart';
import 'paths.dart';
import 'rig.dart';

/// Everything the emulator was left at, kept between runs.
///
/// One file rather than a setting each: what is being remembered is the
/// shape of a session - this zoom, that battery, a card pointed at that
/// folder - and putting it back means putting all of it back.
class EmulatorSettings {
  EmulatorSettings({required this.window, required this.rig, File? file})
    : file = file ?? Paths.settings;

  final EmulatorWindow window;
  final Rig rig;

  /// Where it is kept. Overridable so a test can round-trip through a
  /// temporary file rather than through the user's own.
  final File file;

  /// Long enough that dragging a slider writes once rather than eighty
  /// times, short enough that a crash after a change loses nothing.
  static const _settle = Duration(milliseconds: 400);

  Timer? _pending;

  /// Read what was saved and put it back. Anything missing or unreadable
  /// leaves the default in place - a settings file is a convenience, and a
  /// broken one must not be a broken emulator.
  Future<void> load() async {
    final Map<String, Object?> saved;
    try {
      if (!file.existsSync()) return;
      saved = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    } on Object catch (error) {
      debugPrint('emulator: settings unreadable: $error');
      return;
    }

    if (saved['zoom'] case final num zoom) window.restoreZoom(zoom.toDouble());

    if (saved['appearance'] case final String mode) {
      Appearance.mode.value = AppearanceMode.values.firstWhere(
        (value) => value.name == mode,
        orElse: () => Appearance.mode.value,
      );
    }

    if (saved['scale'] case final String scale) {
      Appearance.scale.value = UiScale.values.firstWhere(
        (value) => value.name == scale,
        orElse: () => Appearance.scale.value,
      );
    }

    if (saved['sleep'] case final Map<String, Object?> sleep) {
      if (sleep['inhibited'] case final bool inhibited) {
        ScreenSleep.inhibited.value = inhibited;
      }
    }

    if (saved['battery'] case final Map<String, Object?> battery) {
      if (battery['percent'] case final num percent) {
        rig.setCharge(percent.round());
      }
      if (battery['charging'] case final bool charging) {
        rig.setCharging(charging);
      }
    }

    if (saved['wifi'] case final Map<String, Object?> wifi) {
      if (wifi['status'] case final String status) {
        rig.setWifi(
          WifiStatus.values.firstWhere(
            (value) => value.name == status,
            orElse: () => rig.wifi.value.status,
          ),
        );
      }
      if (wifi['bars'] case final num bars) rig.setBars(bars.round());
    }

    if (saved['bluetooth'] case final Map<String, Object?> bluetooth) {
      if (bluetooth['status'] case final String status) {
        rig.setBluetooth(
          BluetoothStatus.values.firstWhere(
            (value) => value.name == status,
            orElse: () => rig.bluetooth.value.status,
          ),
        );
      }
    }

    if (saved['mockFmRadio'] case final bool mocked) {
      await rig.fmRadio.restorePreference(mocked);
    }

    // Older host-radio preferences are intentionally ignored.

    if (saved['card'] case final Map<String, Object?> card) {
      if (card['folder'] case final String folder) rig.hostFolder = folder;
      if (card['source'] case final String source) {
        rig.cardSource = CardSource.values.firstWhere(
          (value) => value.name == source,
          orElse: () => rig.cardSource,
        );
      }
      if (card['inserted'] case final bool inserted) {
        rig.cardInserted = inserted;
      }
    }
  }

  /// Save whenever anything moves, from here on.
  void watch() {
    for (final source in _sources) {
      source.addListener(_schedule);
    }
  }

  /// Stop watching - and a change still waiting to be written is written
  /// now, not dropped: the last thing done before the window closes is
  /// the one most worth remembering.
  void dispose() {
    if (_pending != null) {
      _pending!.cancel();
      _pending = null;
      saveSync();
    }
    for (final source in _sources) {
      source.removeListener(_schedule);
    }
  }

  List<Listenable> get _sources => [
    window,
    rig,
    Appearance.mode,
    Appearance.scale,
    ScreenSleep.inhibited,
  ];

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(_settle, save);
  }

  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(_encoded());
    } on FileSystemException catch (error) {
      debugPrint('emulator: settings unwritable: ${error.message}');
    }
  }

  /// [save], without waiting: for the way out, when there is no later.
  void saveSync() {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(_encoded());
    } on FileSystemException catch (error) {
      debugPrint('emulator: settings unwritable: ${error.message}');
    }
  }

  String _encoded() {
    final battery = rig.battery.value;
    final wifi = rig.radios.mockedWifi;
    final bluetooth = rig.radios.mockedBluetooth;
    return const JsonEncoder.withIndent('  ').convert({
      'radioMode': rig.radios.mode.name,
      'mockFmRadio': rig.fmRadio.preferMock,
      'zoom': window.zoom,
      'appearance': Appearance.mode.value.name,
      'scale': Appearance.scale.value.name,
      'sleep': {'inhibited': ScreenSleep.inhibited.value},
      'battery': {'percent': battery.percent, 'charging': battery.charging},
      'wifi': {
        'status': wifi.status.name,
        'bars': wifi.bars,
        'network': wifi.network,
      },
      'bluetooth': {
        'status': bluetooth.status.name,
        'device': bluetooth.device,
      },
      'card': {
        'inserted': rig.cardInserted,
        'source': rig.cardSource.name,
        'folder': rig.hostFolder,
      },
    });
  }
}
