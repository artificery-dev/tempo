import 'dart:js_interop';
import 'browser/js.dart';
import 'device_setup.dart';
import 'browser/session.dart';
import 'browser/storage.dart';

@JS('tempoUsbWasmReady')
external JSPromise<JSObject> get _ready;
@JS('isSecureContext')
external JSBoolean get _secure;
@JS('fetch')
external JSPromise<JSObject> _fetch(JSString path);

class UsbEngine {
  Future<Map<String, dynamic>> prepareFirmwareFromPath(String path) =>
      Future.error(UnsupportedError('Use Choose package in the browser.'));

  Future<void> dispose() => stop();
  bool useLegacyDownloadAgent = false;
  bool verifyWrites = true;
  bool rebootAfterSuccess = true;

  /// First-run choices for the flasher; the browser cannot carry them, as
  /// they travel through Tempo Recovery.
  DeviceSetup? deviceSetup;
  final bool isWeb = true;
  BrowserSession? _usb, _serial;
  BackupDestination? _backup;
  FirmwareDestination? _firmware;
  Future<Map<String, dynamic>> initialize(
    void Function(Map<String, dynamic>) onEvent,
  ) async {
    final userAgent = string(property(navigator, 'userAgent'));
    if (userAgent.contains('Firefox/'))
      return {
        'supported': false,
        'serial_supported': false,
        'message': 'Use a desktop Chromium browser or the native Toolbox.',
      };
    if (!_secure.toDart)
      return {
        'supported': false,
        'serial_supported': false,
        'message': 'Use HTTPS or localhost to connect a device.',
      };
    try {
      final engine = await _ready.toDart;
      final response = await _fetch('DA.img'.toJS).toDart;
      if (!boolean(property(response, 'ok')))
        throw StateError('Could not load the Y2 download agent.');
      final agent = (await invoke(response, 'arrayBuffer') as JSArrayBuffer)
          .toDart
          .asUint8List()
          .toJS;
      void emit(Map<String, dynamic> event) => onEvent({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        ...event,
      });
      _usb = BrowserSession(
        api: property(navigator, 'usb') as JSObject?,
        engine: engine,
        agent: agent,
        serial: false,
        emit: emit,
      );
      _serial = BrowserSession(
        api: property(navigator, 'serial') as JSObject?,
        engine: engine,
        agent: agent,
        serial: true,
        emit: emit,
      );
      _backup = BackupDestination(emit);
      _firmware = FirmwareDestination(engine, emit);
      return {
        'supported': _usb!.supported,
        'serial_supported': _serial!.supported,
        'message': _usb!.supported
            ? 'Connect the powered-off Y2.'
            : 'Use a WebUSB-capable desktop Chromium browser.',
      };
    } catch (error) {
      return {
        'supported': false,
        'serial_supported': false,
        'message':
            'USB engine could not load. Build the Toolbox web assets. $error',
      };
    }
  }

  Future<Map<String, dynamic>> prepareRestore({
    bool legacy = false,
    String? path,
  }) async => {
    'ready': false,
    'message': 'Backup restore requires the native Toolbox.',
  };
  Future<Map<String, dynamic>> prepareBackup({bool resume = false}) async {
    if (resume)
      return {
        'ready': false,
        'message': 'Backup resume requires native Toolbox.',
      };
    try {
      return await _backup!.prepare();
    } catch (error) {
      await _backup?.clear();
      return {'ready': false, 'message': '$error'};
    }
  }

  Future<Map<String, dynamic>> prepareFirmware() async {
    try {
      return await _firmware!.prepare();
    } catch (error) {
      await _firmware?.clear();
      return {'ready': false, 'message': '$error'};
    }
  }

  JSObject? _operation(bool backup, bool flash, bool allowPreloader) => backup
      ? object({
          'kind': 'backup'.toJS,
          'sink': _backup!.take(),
          'rebootAfterSuccess': rebootAfterSuccess.toJS,
        })
      : flash
      ? object({
          'kind': 'flash'.toJS,
          'rebootAfterSuccess': rebootAfterSuccess.toJS,
          'firmware': _firmware!.take(
            allowPreloader,
            verifyWrites: verifyWrites,
          ),
        })
      : null;
  Future<void> choose({
    bool backup = false,
    bool flash = false,
    bool allowPreloader = false,
    bool resume = false,
  }) async {
    if ((backup || flash) && !useLegacyDownloadAgent) {
      throw UnsupportedError(
        'Tempo Recovery transfers require the desktop Toolbox. Select Legacy Download Agent in Advanced to use browser transfers.',
      );
    }
    if (resume) throw UnsupportedError('Resume requires native Toolbox.');
    if (deviceSetup != null && !deviceSetup!.isEmpty) {
      throw UnsupportedError('Device setup requires the desktop Toolbox.');
    }
    await _usb?.choose(_operation(backup, flash, allowPreloader));
  }

  Future<void> chooseSerial({
    bool backup = false,
    bool flash = false,
    bool allowPreloader = false,
    bool resume = false,
  }) async {
    if ((backup || flash) && !useLegacyDownloadAgent) {
      throw UnsupportedError(
        'Tempo Recovery transfers require the desktop Toolbox. Select Legacy Download Agent in Advanced to use browser transfers.',
      );
    }
    if (resume) throw UnsupportedError('Resume requires native Toolbox.');
    if (deviceSetup != null && !deviceSetup!.isEmpty) {
      throw UnsupportedError('Device setup requires the desktop Toolbox.');
    }
    await _serial?.choose(_operation(backup, flash, allowPreloader));
  }

  Future<void> watch() async {
    await _usb?.watch();
  }

  Future<void> stop() async {
    await Future.wait([
      if (_usb != null) _usb!.stop(),
      if (_serial != null) _serial!.stop(),
      if (_backup != null) _backup!.clear(),
    ]);
  }
}
