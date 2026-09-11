import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file/local.dart';
import 'package:path_provider/path_provider.dart';

import 'package:file_selector/file_selector.dart';
import 'package:toolbox_core/toolbox_core.dart';

class UsbEngine {
  final bool isWeb = false;
  bool useLegacyDownloadAgent = false;
  bool verifyWrites = true;
  bool rebootAfterSuccess = true;

  /// First-run choices to write into the flashed root filesystem, or null.
  DeviceSetup? deviceSetup;
  var _operations = ToolboxOperations();
  String? get agent => _operations.agent;
  String? get preloader => _operations.preloader;

  void configure({String? agent, String? preloader}) {
    _operations = ToolboxOperations(
      engine: _operations.engine,
      agent: agent,
      preloader: preloader,
    );
  }

  Future<EngineEvent> partitions() => _operations.partitions(onEvent: _onEvent);
  Future<EngineEvent> fetch(String name, String path) =>
      _operations.fetch(name, path, onEvent: _onEvent);
  late void Function(EngineEvent) _onEvent;
  String? _backupPath, _firmwarePath, _restorePath, _resumeBackupPath;
  Future<EngineEvent> initialize(void Function(EngineEvent) onEvent) {
    _onEvent = onEvent;
    return _operations.initialize();
  }

  Future<Map<String, dynamic>> prepareBackup({bool resume = false}) async {
    _resumeBackupPath = null;
    _backupPath = null;
    if (resume) {
      _resumeBackupPath = await getDirectoryPath(
        confirmButtonText: 'Select recovery or legacy backup',
      );
      if (_resumeBackupPath == null) return {'ready': false};
    }

    final date = DateTime.now().toIso8601String().substring(0, 10);
    final location = await getSaveLocation(
      suggestedName: 'innioasis-y2-$date-emmc.img.gz',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Compressed Y2 eMMC image', extensions: ['gz']),
      ],
    );
    _backupPath = location?.path;
    return {
      'ready': _backupPath != null,
      if (_backupPath != null)
        'filename': _backupPath!.split(Platform.pathSeparator).last,
    };
  }

  Future<Map<String, dynamic>> prepareFirmware() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Y2 firmware or SPFT ROM',
          extensions: ['y2-firmware', 'zip', 'txt'],
        ),
      ],
    );
    if (file == null) {
      return {'ready': false, 'message': 'No firmware package selected.'};
    }
    return prepareFirmwareFromPath(file.path);
  }

  Future<Map<String, dynamic>> prepareFirmwareFromPath(String path) async {
    _restorePath = null;
    if (_operations.engine.executable == null) {
      return {'ready': false, 'message': 'The Rust USB engine is unavailable.'};
    }
    final legacy = !path.toLowerCase().endsWith('.y2-firmware');
    final event = legacy
        ? await _operations.engine.run(['preview-spft', path], onEvent: (_) {})
        : await _operations.inspectFirmware(path);
    if (event['event'] != 'firmware-info') {
      return {
        'ready': false,
        'message': event['message'] ?? 'Cannot read firmware metadata.',
      };
    }
    final rgba = event.remove('logo_rgba');
    if (rgba is String && rgba.length == 120 * 90 * 8) {
      final bytes = Uint8List.fromList([
        for (var i = 0; i < rgba.length; i += 2)
          int.parse(rgba.substring(i, i + 2), radix: 16),
      ]);
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bytes,
        120,
        90,
        ui.PixelFormat.rgba8888,
        decoded.complete,
      );
      final image = await decoded.future;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png != null) {
        (event['firmware'] as Map)['icon'] =
            'data:image/png;base64,${base64Encode(png.buffer.asUint8List())}';
      }
    }
    event['filename'] = const LocalFileSystem().path.basename(path);
    _onEvent(event);
    _onEvent({
      'event': 'firmware-prepare-started',
      'message': 'Validating package…',
    });
    // Publish the lightweight preview before launching the expensive stage.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Large firmware images must not compete with the OS's RAM-backed /tmp quota.
    final fs = const LocalFileSystem();
    final cache = fs.directory(
      fs.path.join(
        (await getApplicationCacheDirectory()).path,
        'firmware-staging',
      ),
    );
    await cache.create(recursive: true);
    final previous = _firmwarePath;
    _firmwarePath = null;
    if (previous != null) {
      final old = fs.directory(previous);
      if (await old.exists()) await old.delete(recursive: true);
    }
    final prepared = await _operations.engine.run(
      [legacy ? 'prepare-spft' : 'prepare-firmware', path, cache.path],
      onEvent: (event) {
        if (event['event'] == 'firmware-prepare-progress') _onEvent(event);
      },
    );
    if (prepared['event'] != 'result' || prepared['path'] is! String) {
      return {
        'ready': false,
        'message': prepared['message'] ?? 'Firmware validation failed.',
      };
    }
    _firmwarePath = prepared['path'] as String;
    final verified = await _operations.inspectFirmware(_firmwarePath!);
    return {
      ...verified,
      ...event,
      'ready': true,
      'images': verified['images'],
      'writes': verified['writes'],
      'bytes': verified['bytes'],
    };
  }

  Future<EngineEvent> prepareRestore({
    bool legacy = false,
    String? path,
  }) async {
    final candidate =
        path ??
        (legacy
            ? await getDirectoryPath(confirmButtonText: 'Select legacy backup')
            : (await openFile(
                acceptedTypeGroups: const [
                  XTypeGroup(label: 'Y2 eMMC gzip backup', extensions: ['gz']),
                ],
              ))?.path);
    if (candidate != null && !legacy) {
      final file = const LocalFileSystem().file(candidate);
      if (!file.existsSync()) {
        throw const FormatException('Backup file does not exist.');
      }
      final input = file.openSync();
      try {
        final magic = input.readSync(2);
        if (magic.length != 2 || magic[0] != 0x1f || magic[1] != 0x8b) {
          throw const FormatException(
            'Choose a gzip-compressed Toolbox backup.',
          );
        }
      } finally {
        input.closeSync();
      }
    }
    if (candidate == null) return {'ready': false};
    _restorePath = candidate;
    return {'ready': true, 'filename': candidate};
  }

  Future<void> choose({
    bool backup = false,
    bool flash = false,
    bool allowPreloader = false,
    bool resume = false,
  }) => watch(
    backup: backup,
    flash: flash,
    allowPreloader: allowPreloader,
    resume: resume,
  );
  Future<void> chooseSerial({
    bool backup = false,
    bool flash = false,
    bool allowPreloader = false,
    bool resume = false,
  }) => watch(
    backup: backup,
    flash: flash,
    allowPreloader: allowPreloader,
    resume: resume,
  );
  Future<void> watch({
    bool backup = false,
    bool flash = false,
    bool allowPreloader = false,
    bool resume = false,
  }) async {
    try {
      final result = backup && _resumeBackupPath != null
          ? await _operations.resumeBackup(
              _resumeBackupPath!,
              _backupPath ??
                  (throw StateError('Choose a backup output first.')),
              onEvent: _onEvent,
            )
          : backup
          ? await _operations.backup(
              _backupPath ??
                  (throw StateError('Choose a backup output first.')),
              legacyDownloadAgent: useLegacyDownloadAgent,
              rebootAfterSuccess: rebootAfterSuccess,
              onEvent: _onEvent,
            )
          : flash && _restorePath != null
          ? await _operations.restore(
              _restorePath!,
              allowPreloader: allowPreloader,
              resume: resume,
              verifyWrite: verifyWrites,
              legacyDownloadAgent: useLegacyDownloadAgent,
              rebootAfterSuccess: rebootAfterSuccess,
              onEvent: _onEvent,
            )
          : flash
          ? await _operations.install(
              _firmwarePath ??
                  (throw StateError('Choose a firmware package first.')),
              allowPreloader: allowPreloader,
              resume: resume,
              verifyWrite: verifyWrites,
              legacyDownloadAgent: useLegacyDownloadAgent,
              rebootAfterSuccess: rebootAfterSuccess,
              setup: deviceSetup,
              onEvent: _onEvent,
            )
          : await _operations.probe(onEvent: _onEvent);
      if (result['event'] != 'cancelled') _onEvent(result);
    } catch (error) {
      _onEvent({'event': 'error', 'message': '$error'});
    }
  }

  Future<void> dispose() async {
    await stop();
    final path = _firmwarePath;
    _firmwarePath = null;
    if (path != null) {
      final directory = const LocalFileSystem().directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  Future<void> stop() => _operations.cancel();
}
