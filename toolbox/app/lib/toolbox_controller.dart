import 'emulator/src/event_log.dart';
import 'package:tempo_logger/tempo_logger.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:tempo_usb/tempo_usb.dart' show DeviceSetup;
import 'engine.dart';

final toolboxControllerProvider = ChangeNotifierProvider<ToolboxController>(
  (ref) => ToolboxController(log: ref.read(toolboxLogsProvider)),
);

/// Shared operation state survives page navigation. The USB engine still owns
/// transfer validation, cancellation and device-write policy.
class ToolboxController extends ChangeNotifier {
  ToolboxController({UsbEngine? engine, this.log})
    : engine = engine ?? UsbEngine() {
    unawaited(initialize());
  }
  bool _disposed = false;
  bool get mounted => !_disposed;
  void _update(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  void updateUi(VoidCallback change) => _update(change);
  void setPreloaderFlashing(bool enabled) =>
      _update(() => allowPreloaderFlash = enabled);
  @override
  void dispose() {
    _disposed = true;
    unawaited(engine.dispose());
    super.dispose();
  }

  final UsbEngine engine;
  final LogWriter? log;
  Map<String, dynamic>? firmwareInfo;
  DateTime? operationStarted;
  double? transferBytesPerSecond;
  String? task, firmware;
  String? firmwareVersion;
  bool firmwareReady = false, firmwareIncludesPreloader = false;
  bool backupReady = false;
  bool backupDownloadsAutomatically = true;
  String? backupName;
  int? backupCompleted, backupTotal;
  int? transferTaskCompleted, transferTaskTotal;
  int? largeTransferPartitionCount;
  bool get showOverallFlashProgress =>
      (largeTransferPartitionCount ??
          (firmwareInfo?['legacy'] == true ? 2 : 1)) >
      1;

  final List<Map<String, dynamic>> events = [];
  bool supported = false, busy = false, initialized = false;
  bool stopping = false;
  bool serialSupported = false;
  bool advanced = false;
  bool get rebootAfterSuccess => engine.rebootAfterSuccess;
  void setRebootAfterSuccess(bool value) {
    if (!busy) _update(() => engine.rebootAfterSuccess = value);
  }

  bool get verifyWrites => engine.verifyWrites;
  void setVerifyWrites(bool value) {
    if (!busy) _update(() => engine.verifyWrites = value);
  }

  bool get useLegacyDownloadAgent => engine.useLegacyDownloadAgent;
  void setLegacyDownloadAgent(bool enabled) {
    if (busy) return;
    _update(() => engine.useLegacyDownloadAgent = enabled);
  }

  bool allowPreloaderFlash = false;
  bool resumeWrites = false;

  /// First-run choices for a flash; whatever is blank the player asks for.
  DeviceSetup deviceSetup = const DeviceSetup();
  bool deviceSetupOpen = false;
  void setDeviceSetup(DeviceSetup value) {
    if (!busy) _update(() => deviceSetup = value);
  }

  /// Whether the task can carry first-run choices: they reach the player
  /// through Tempo Recovery, so only a flash from the desktop Toolbox.
  bool get deviceSetupAvailable =>
      task == 'Flash' && !engine.isWeb && !useLegacyDownloadAgent;
  bool preloaderWriting = false;
  bool errorCopied = false;
  String status = 'Loading the USB engine…', phase = 'ready';
  Map<String, dynamic>? report;

  void selectTask(String? nextTask) {
    if (busy || task == nextTask) return;
    _update(() {
      if (task != nextTask) {
        firmwareReady = false;
        firmware = null;
        firmwareVersion = null;
        firmwareInfo = null;
      }
      task = nextTask;
      report = null;
      backupDownloadsAutomatically = true;
      backupCompleted = null;
      backupTotal = null;
      allowPreloaderFlash = false;
    });
  }

  Future<void> prepareRestore({bool legacy = false, String? path}) async {
    if (busy) return;
    _update(() => busy = true);
    Map<String, dynamic> result;
    try {
      result = await engine.prepareRestore(legacy: legacy, path: path);
    } catch (error) {
      event({'event': 'error', 'message': '$error'});
      return;
    } finally {
      _update(() => busy = false);
    }
    if (!mounted || result['ready'] != true) return;
    _update(() {
      task = 'Restore';
      firmware = result['filename']?.toString();
      firmwareVersion = null;
      firmwareReady = true;
      firmwareIncludesPreloader = true;
      allowPreloaderFlash = false;
      report = null;
      status =
          'The backup will be fully decompressed and validated before USB opens. BOOT1 remains protected by default.';
    });
  }

  Future<void> prepareFirmware({String? path}) async {
    if (busy) return;
    selectTask('Flash');
    _update(() {
      busy = true;
      phase = 'firmware-prepare-started';
      status = 'Opening a .y2-firmware package…';
      firmwareInfo = null;
      firmwareReady = false;
      backupCompleted = null;
      backupTotal = null;
    });
    try {
      final result = path == null
          ? await engine.prepareFirmware()
          : await engine.prepareFirmwareFromPath(path);
      if (!mounted) return;
      if (result['ready'] != true) {
        event({
          'event': 'error',
          'message':
              result['message']?.toString() ??
              'Firmware package could not be opened.',
          'stage': 'package-validation',
        });
        return;
      }
      _update(() {
        busy = false;
        firmwareReady = result['ready'] == true;
        if (firmwareReady) {
          final info = result['firmware'] as Map<String, dynamic>;
          firmwareInfo = result;
          firmware = info['name']?.toString();
          firmwareVersion = info['version']?.toString();
          firmwareIncludesPreloader = result['includes_preloader'] == true;
          phase = 'firmware-ready';
          backupCompleted = null;
          backupTotal = null;
          status = 'Firmware package verified and ready.';
        } else {
          phase = 'error';
          status =
              result['message']?.toString() ??
              'Firmware package could not be opened.';
        }
      });
    } catch (error) {
      event({'event': 'error', 'message': '$error'});
    }
  }

  Future<void> prepareBackup({bool resume = false}) async {
    if (busy) return;
    selectTask('Backup');
    _update(() => busy = true);
    try {
      final result = await engine.prepareBackup(resume: resume);
      if (!mounted) return;
      _update(() {
        backupReady = result['ready'] == true;
        backupName = result['filename'] as String?;
        backupDownloadsAutomatically = result['automatic_download'] != false;
        if (backupReady && engine.isWeb) {
          status = backupDownloadsAutomatically
              ? 'Ready. The completed backup will download automatically.'
              : 'Ready. The backup will be saved directly to $backupName.';
          phase = 'ready';
        } else if (result['message'] case final String message) {
          status = message;
          phase = 'error';
        }
      });
    } catch (error) {
      event({'event': 'error', 'message': '$error'});
    } finally {
      _update(() => busy = false);
    }
  }

  Future<void> initialize() async {
    try {
      final result = await engine.initialize(event);
      if (mounted) {
        _update(() {
          supported = result['supported'] == true;
          serialSupported = result['serial_supported'] == true;
          status = result['message'] as String;
          initialized = true;
        });
      }
    } catch (error) {
      if (mounted) {
        _update(() {
          status = 'USB engine unavailable: $error';
          initialized = true;
        });
      }
    }
  }

  void event(Map<String, dynamic> event) {
    if (!mounted) return;
    final kind = event['event']?.toString() ?? 'event';
    final source = switch (task) {
      'Backup' => 'backup',
      'Restore' => 'restore',
      'Flash' => 'flasher',
      _ => 'device',
    };
    log?.write(
      LogRecord(
        tag: source,
        level: kind == 'error'
            ? LogLevel.error
            : kind == 'warning'
            ? LogLevel.warning
            : LogLevel.info,
        message: event['message']?.toString() ?? kind,
        metadata: event,
      ),
    );
    _update(() {
      events.add({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        ...event,
      });
      if (events.length > 250) events.removeAt(0);
      final kind = event['event'];
      if (kind == 'waiting' || kind == 'firmware-prepare-started') {
        largeTransferPartitionCount = null;
      }
      if (event['large_partition_count'] case final num count) {
        largeTransferPartitionCount = count.toInt();
      }
      if (event['bytes_per_second'] case final num speed) {
        transferBytesPerSecond = speed.isFinite && speed >= 0
            ? speed.toDouble()
            : null;
      }
      if ({
        'waiting',
        'firmware-prepare-started',
        'flash-started',
        'backup-started',
      }.contains(kind)) {
        transferBytesPerSecond = null;
        transferTaskCompleted = null;
        transferTaskTotal = null;
      }
      if (kind == 'recovery-boot-progress' || kind == 'recovery-starting') {
        phase = kind as String;
        busy = true;
        status = event['message']?.toString() ?? 'Starting Tempo Recovery…';
        transferTaskCompleted = (event['completed'] as num?)?.toInt();
        transferTaskTotal = (event['total'] as num?)?.toInt();
      }
      if (kind == 'flash-progress') {
        transferTaskCompleted = (event['task_completed'] as num?)?.toInt();
        transferTaskTotal = (event['task_total'] as num?)?.toInt();
      }
      if (kind == 'flash-started' || kind == 'backup-started') {
        operationStarted = DateTime.now();
      }

      if (['choosing', 'waiting', 'capturing'].contains(kind)) {
        phase = kind as String;
        busy = true;
      }
      if (kind == 'backup-started') {
        phase = kind as String;
        busy = true;
        backupCompleted = 0;
        backupTotal = event['total'] as int?;
      }
      if ([
        'progress',
        'backup-progress',
        'backup-prefix-validation',
        'backup-prefix-verified',
        'backup-finalizing',
      ].contains(kind)) {
        phase = kind as String;
        backupCompleted = event['completed'] as int?;
        backupTotal = event['total'] as int?;
        if (kind == 'backup-prefix-validation') {
          status = 'Validating saved backup chunks…';
        }
        if (kind == 'backup-prefix-verified') {
          status = 'Checking saved chunks against the connected Y2…';
        }
        if (kind == 'backup-finalizing') {
          status = 'Creating the complete gzip backup…';
        }
      }
      if (kind == 'firmware-prepare-started' || kind == 'flash-started') {
        phase = kind as String;
        busy = true;
        backupCompleted = (event['completed'] as num?)?.toInt() ?? 0;
        backupTotal = (event['total'] as num?)?.toInt();
      }
      if (kind == 'firmware-prepare-progress' ||
          kind == 'firmware-verify-progress' ||
          kind == 'flash-progress') {
        phase = kind as String;
        busy = true;
        backupCompleted = (event['completed'] as num?)?.toInt();
        backupTotal = (event['total'] as num?)?.toInt();
        final operation = event['phase']?.toString();
        final mapping = event['mapping']?.toString();
        preloaderWriting =
            operation == 'writing' && event['region']?.toString() == 'boot1';
        if (operation != null) {
          status =
              '${operation[0].toUpperCase()}${operation.substring(1)}${mapping == null ? '' : ' $mapping'}…';
        }
      }
      if (kind == 'firmware-info') {
        firmwareInfo = event;
      }
      if (kind == 'waiting') {
        backupCompleted = null;
        backupTotal = null;
      }
      if (kind == 'firmware-prepare-started') {
        status = 'Checking firmware data before connecting…';
      }
      if (kind == 'firmware-ready') {
        phase = kind as String;
        firmwareReady = true;
      }
      if (kind == 'backup-complete') {
        backupName = (event['path'] ?? backupName)?.toString();
      }
      if (['error', 'result', 'stopped', 'flash-complete'].contains(kind)) {
        phase = kind as String;
        busy = false;
        preloaderWriting = false;
        if (kind == 'error' && task == 'Backup') backupReady = false;
        if (kind == 'error') errorCopied = false;
      }
      if (event['message'] case final String message) status = message;
      if (kind == 'result') {
        report = event['report'] as Map<String, dynamic>;
        if ((task == 'Flash' || task == 'Restore') &&
            report!['storage_written'] == true) {
          status =
              event['message']?.toString() ??
              (verifyWrites
                  ? 'Firmware installed and verified.${rebootAfterSuccess ? ' Restarting the Y2.' : ''}'
                  : 'Firmware installed without readback verification.${rebootAfterSuccess ? ' Restarting the Y2.' : ''}');
        } else if (task == 'Backup' && event['bytes'] != null) {
          backupName = (event['backup_file'] ?? backupName)?.toString();
          backupReady = false;
          status = engine.isWeb
              ? backupDownloadsAutomatically
                    ? 'Backup complete. Download started: $backupName'
                    : 'Backup complete: $backupName'
              : event['message']?.toString() ?? 'Backup complete: $backupName';
        } else {
          status = report!['compatible_chip'] == true
              ? 'The MediaTek connection works. The chip matches the Y2 family.'
              : 'This chip does not match the Y2. No installation is available.';
        }
      }
      if (stopping) busy = true;
    });
  }

  Future<void> start({bool serial = false}) async {
    if (busy ||
        !supported ||
        (task == 'Backup' && !backupReady) ||
        ((task == 'Flash' || task == 'Restore') && !firmwareReady)) {
      return;
    }
    final setup = deviceSetupAvailable && !deviceSetup.isEmpty
        ? deviceSetup
        : null;
    if (setup != null && setup.validate().isNotEmpty) {
      final problem = setup.validate().entries.first;
      event({
        'event': 'error',
        'message':
            'Device setup, ${DeviceSetup.labels[problem.key]!.toLowerCase()}: ${problem.value}',
      });
      return;
    }
    engine.deviceSetup = setup;
    _update(() {
      busy = true;
      report = null;
      phase = 'waiting';
      transferBytesPerSecond = null;
      operationStarted = DateTime.now();
      errorCopied = false;
      if (task == 'Backup' || (task == 'Flash' || task == 'Restore')) {
        backupCompleted = null;
        backupTotal = null;
      }
    });
    try {
      if (serial) {
        await engine.chooseSerial(
          backup: task == 'Backup',
          flash: (task == 'Flash' || task == 'Restore'),
          allowPreloader: allowPreloaderFlash,
          resume: resumeWrites,
        );
      } else {
        await engine.choose(
          backup: task == 'Backup',
          flash: (task == 'Flash' || task == 'Restore'),
          allowPreloader: allowPreloaderFlash,
          resume: resumeWrites,
        );
      }
    } catch (error) {
      event({'event': 'error', 'message': '$error'});
    }
  }

  Future<void> stop() async {
    if (!busy || stopping || preloaderWriting) return;
    _update(() => stopping = true);
    try {
      final downloadAgentRunning =
          (task == 'Backup' || (task == 'Flash' || task == 'Restore')) &&
          backupTotal != null;
      await engine.stop();
      event({
        'event': 'stopped',
        'message': task == 'Backup'
            ? downloadAgentRunning
                  ? 'Backup stopped and the incomplete file was discarded. The installer asked the Y2 to return to firmware.'
                  : 'Backup stopped before the download agent was ready. Power-cycle the Y2 before trying again.'
            : (task == 'Flash' || task == 'Restore')
            ? downloadAgentRunning
                  ? 'Installation stopped. The installer asked the Y2 to return to firmware.'
                  : 'Installation stopped before the download agent was ready. Power-cycle the Y2 before trying again.'
            : 'Connection check stopped. Power-cycle the Y2 before trying again.',
      });
    } catch (error) {
      event({
        'event': 'error',
        'message': 'Could not stop the operation: $error',
      });
    } finally {
      _update(() {
        stopping = false;
        busy = false;
      });
    }
  }

  Future<void> copyError() async {
    await Clipboard.setData(ClipboardData(text: status));
    if (mounted) _update(() => errorCopied = true);
  }
}
