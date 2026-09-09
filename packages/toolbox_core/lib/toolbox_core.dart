import 'dart:io';
import 'package:tempo_usb/tempo_usb.dart';
export 'package:tempo_usb/tempo_usb.dart' show EngineEvent;

/// Shared end-user operation policy used by the GUI and command line.
class ToolboxOperations {
  ToolboxOperations({NativeUsbEngine? engine, this.preloader, this.agent})
    : engine = engine ?? NativeUsbEngine();
  final NativeUsbEngine engine;
  final String? preloader, agent;
  Future<EngineEvent> _run(
    List<String> arguments, {
    required void Function(EngineEvent) onEvent,
  }) => engine.run([
    ...arguments,
    if (preloader != null && arguments.first != 'recovery') ...[
      '--preloader',
      File(preloader!).absolute.path,
    ],
  ], onEvent: onEvent);
  Future<EngineEvent> initialize() => engine.initialize();
  Future<void> cancel() => engine.stop();
  Future<EngineEvent> probe({
    int seconds = 30,
    required void Function(EngineEvent) onEvent,
  }) {
    if (seconds < 1 || seconds > 300)
      throw ArgumentError.value(seconds, 'seconds', 'must be 1–300');
    return _run(['probe', '$seconds'], onEvent: onEvent);
  }

  Future<EngineEvent> partitions({
    required void Function(EngineEvent) onEvent,
  }) => _run(['partitions', _agent()], onEvent: onEvent);

  Future<EngineEvent> fetch(
    String partition,
    String path, {
    required void Function(EngineEvent) onEvent,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(partition))
      throw ArgumentError('Invalid partition name.');
    if (await File(path).exists())
      throw StateError('Partition output already exists.');
    if (!await File(path).absolute.parent.exists())
      throw StateError('Partition output directory does not exist.');
    return _run([
      'fetch',
      _agent(),
      partition,
      File(path).absolute.path,
    ], onEvent: onEvent);
  }

  Future<EngineEvent> inspectFirmware(String path) async {
    if (!await Directory(path).exists()) await _input(path);
    return _run([
      'inspect-firmware',
      File(path).absolute.path,
    ], onEvent: (_) {});
  }

  Future<EngineEvent> inspectRaw(String target, String path) async {
    await _input(path);
    if (!['BOOTIMG', 'LOGO', 'BOOT1'].contains(target.toUpperCase()))
      throw ArgumentError('Raw target must be BOOTIMG, LOGO or BOOT1.');
    return _run([
      'inspect-raw',
      target,
      File(path).absolute.path,
    ], onEvent: (_) {});
  }

  /// Guarded BOOTIMG/LOGO operation; the engine keeps its hardware write gate
  /// closed until address validation. Dry-run still saves a full safety backup.
  Future<EngineEvent> installRaw(
    String target,
    String input,
    String safetyPath, {
    bool dryRun = false,
    bool forceBootHeader = false,
    required void Function(EngineEvent) onEvent,
  }) async {
    target = target.toUpperCase();
    if (!['BOOTIMG', 'LOGO'].contains(target))
      throw ArgumentError('Raw installation permits only BOOTIMG and LOGO.');
    if (forceBootHeader && target != 'BOOTIMG')
      throw ArgumentError('The existing-header override requires BOOTIMG.');
    await _input(input);
    for (final path in [
      safetyPath,
      if (target == 'LOGO') '$safetyPath.logo.img',
    ]) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound)
        throw StateError('Safety backup output already exists: $path');
      if (!await File(path).absolute.parent.exists())
        throw StateError('Safety backup directory does not exist.');
    }
    return _run([
      'flash-raw',
      _agent(),
      target,
      File(input).absolute.path,
      File(safetyPath).absolute.path,
      if (dryRun) '--dry-run',
      if (forceBootHeader) '--force-boot-header',
    ], onEvent: onEvent);
  }

  Future<EngineEvent> backup(
    String path, {
    bool legacyDownloadAgent = false,
    bool rebootAfterSuccess = true,
    required void Function(EngineEvent) onEvent,
  }) async {
    if (await File(path).exists())
      throw StateError('Backup output already exists: $path');
    if (!await File(path).absolute.parent.exists())
      throw StateError('Backup output directory does not exist.');
    return _run([
      if (!legacyDownloadAgent) 'recovery',
      'backup',
      if (legacyDownloadAgent) _agent(),
      File(path).absolute.path,
      if (!rebootAfterSuccess) '--no-reboot',
    ], onEvent: onEvent);
  }

  Future<EngineEvent> resumeBackup(
    String input,
    String output, {
    required void Function(EngineEvent) onEvent,
  }) async {
    if (!await Directory(input).exists())
      throw ArgumentError(
        'Backup resume needs a legacy or recovery directory.',
      );
    if (await File(output).exists())
      throw StateError('Backup output already exists.');
    if (!await File(output).absolute.parent.exists())
      throw StateError('Backup output directory does not exist.');
    return _run([
      'backup-resume',
      _agent(),
      Directory(input).absolute.path,
      File(output).absolute.path,
    ], onEvent: onEvent);
  }

  Future<EngineEvent> install(
    String path, {
    bool allowPreloader = false,
    bool resume = false,
    bool verifyWrite = true,
    bool legacyDownloadAgent = false,
    bool rebootAfterSuccess = true,
    required void Function(EngineEvent) onEvent,
  }) async {
    final info = await inspectFirmware(path);
    if (info['event'] != 'firmware-info') return info;
    return _run([
      if (!legacyDownloadAgent) 'recovery',
      'flash',
      if (legacyDownloadAgent) _agent(),
      File(path).absolute.path,
      if (allowPreloader) '--allow-preloader',
      if (resume) '--resume',
      if (!verifyWrite) '--no-verify',
      if (!rebootAfterSuccess) '--no-reboot',
    ], onEvent: onEvent);
  }

  /// Restore validates/stages the whole backup before opening USB. RPMB is
  /// always skipped; BOOT1 is preserved unless explicitly authorized.
  Future<EngineEvent> restore(
    String path, {
    bool allowPreloader = false,
    bool resume = false,
    bool verifyWrite = true,
    bool legacyDownloadAgent = false,
    bool rebootAfterSuccess = true,
    required void Function(EngineEvent) onEvent,
  }) async {
    if (!await File(path).exists() && !await Directory(path).exists()) {
      throw ArgumentError('Backup input does not exist: $path');
    }
    return _run([
      if (!legacyDownloadAgent) 'recovery',
      'restore',
      if (legacyDownloadAgent) _agent(),
      File(path).absolute.path,
      if (allowPreloader) '--allow-preloader',
      if (resume) '--resume',
      if (!verifyWrite) '--no-verify',
      if (!rebootAfterSuccess) '--no-reboot',
    ], onEvent: onEvent);
  }

  String _agent() => agent == null
      ? engine.agent ??
            (throw StateError('The DA.img resource is unavailable.'))
      : File(agent!).absolute.path;
  static Future<void> _input(String path) async {
    if (!await File(path).exists())
      throw ArgumentError('Input file does not exist: $path');
  }
}
