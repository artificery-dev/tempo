import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'js.dart';
import 'transports.dart';

/// Permission, lifetime and reconnect policy. Protocol execution stays in Wasm.
class BrowserSession {
  BrowserSession({
    required this.api,
    required this.engine,
    required this.agent,
    required this.serial,
    required this.emit,
  }) {
    if (api == null) return;
    call(api!, 'addEventListener', [
      'disconnect'.toJS,
      ((JSObject event) {
        final device =
            property(event, serial ? 'port' : 'device') as JSObject? ??
            property(event, 'target') as JSObject;
        _retired.remove(device);
        send('disconnected');
      }).toJS,
    ]);
    if (!serial)
      call(api!, 'addEventListener', [
        'connect'.toJS,
        ((JSObject event) {
          final device = property(event, 'device') as JSObject;
          if (_candidate(device)) {
            send('connected');
            if (_armed && !_busy) unawaited(_capture(device, _operation));
          }
        }).toJS,
      ]);
  }
  final JSObject? api;
  final JSObject engine;
  final JSUint8Array agent;
  final bool serial;
  final void Function(Map<String, dynamic>) emit;
  int _generation = 0;
  bool _armed = false, _busy = false;
  Timer? _timer;
  JSObject? _operation;
  BrowserPort? _usb;
  SerialTransport? _serial;
  Future<void>? _active;
  final Set<JSObject> _retired = {};
  late final JSObject bridge = createJSInteropWrapper(this);
  void send(String event, [Map<String, dynamic> extra = const {}]) => emit({
    'event': event,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    if (serial) 'transport': 'webserial',
    ...extra,
  });
  bool _candidate(JSObject device) {
    final info = serial ? call(device, 'getInfo') as JSObject : device;
    if (property(info, serial ? 'usbVendorId' : 'vendorId') == null ||
        property(info, serial ? 'usbProductId' : 'productId') == null)
      return false;
    return integer(property(info, serial ? 'usbVendorId' : 'vendorId')) ==
            0xe8d &&
        [0x2000, 0x2001, 3].contains(
          integer(property(info, serial ? 'usbProductId' : 'productId')),
        );
  }

  JSObject? _sink(JSObject? operation) =>
      operation != null && string(property(operation, 'kind')) == 'backup'
      ? property(operation, 'sink') as JSObject
      : null;
  Future<void> _abort(JSObject? operation) async {
    final sink = _sink(operation);
    if (sink != null)
      await ignoreFailure(invoke(sink, 'abort', ['Cancelled'.toJS]));
  }

  @JSExport()
  bool get supported => api != null;
  @JSExport('choose')
  JSPromise<JSAny?> jsChoose() => choose().then<JSAny?>((_) => null).toJS;
  @JSExport('chooseBackup')
  JSPromise<JSAny?> jsBackup(JSObject sink) => choose(
    object({'kind': 'backup'.toJS, 'sink': sink}),
  ).then<JSAny?>((_) => null).toJS;
  @JSExport('chooseFlash')
  JSPromise<JSAny?> jsFlash(JSObject firmware) => choose(
    object({'kind': 'flash'.toJS, 'firmware': firmware}),
  ).then<JSAny?>((_) => null).toJS;
  Future<void> choose([JSObject? operation]) async {
    if (api == null || _armed || _busy) {
      await _abort(operation);
      return;
    }
    final run = ++_generation;
    _armed = true;
    _operation = operation;
    send('choosing', {
      'message': 'Connect the powered-off Y2 and select its MediaTek entry.',
    });
    try {
      // Preserve browser user activation: permission call precedes every await.
      final device =
          await invoke(api!, serial ? 'requestPort' : 'requestDevice', [
                {
                  'filters': [
                    for (final product in [0x2000, 0x2001, 3])
                      {
                        serial ? 'usbVendorId' : 'vendorId': 0xe8d,
                        serial ? 'usbProductId' : 'productId': product,
                      },
                  ],
                }.jsify(),
              ])
              as JSObject;
      if (run != _generation) {
        await _abort(operation);
        return;
      }
      if (!_candidate(device))
        throw StateError('Selected device is not a MediaTek boot device.');
      send('permission');
      await _capture(device, operation);
    } catch (error) {
      await _abort(operation);
      if (run == _generation) {
        _armed = false;
        _operation = null;
        send('error', {'message': '$error'});
      }
    }
  }

  Future<void> _capture(JSObject device, JSObject? operation) {
    if (_busy || !_armed) return Future.value();
    return _active = _run(device, operation);
  }

  Future<void> _run(JSObject device, JSObject? operation) async {
    _busy = true;
    _timer?.cancel();
    final run = _generation, elapsed = Stopwatch()..start();
    final sink = _sink(operation);
    Map<String, dynamic>? outcome;
    void current() {
      if (run != _generation) throw StateError('Cancelled');
    }

    try {
      if (_retired.contains(device))
        throw StateError(
          'Physically disconnect this device before another attempt.',
        );
      send('capturing', {
        'message': 'Opening the preloader and checking its chip.',
      });
      late JSObject transport;
      late Map<String, dynamic> layout;
      if (serial) {
        final session = SerialTransport(
          device,
          trace: (event) {
            if (run == _generation &&
                (operation == null ||
                    event['state'] == 'failed' ||
                    event['stage'] == 'serial-open' ||
                    event['stage'] == 'serial-signals'))
              send('serial-stage', event);
          },
        );
        _serial = session;
        await session.open();
        current();
        layout = {
          'interface': 0,
          'alternate': 0,
          'control': null,
          'input': 0,
          'output': 0,
        };
        if (operation != null) session.timeoutMs = 10000;
        transport = session.bridge;
      } else {
        final session = BrowserPort(device, {});
        _usb = session;
        await session.transfer(() => invoke(device, 'open'));
        current();
        final configurations = objects(property(device, 'configurations'));
        if (configurations.length != 1)
          throw StateError('Expected one USB configuration.');
        if (property(device, 'configuration') == null)
          await session.transfer(
            () => invoke(device, 'selectConfiguration', [
              property(configurations.single, 'configurationValue'),
            ]),
          );
        current();
        final interfaces = <Map<String, dynamic>>[];
        for (final interface in objects(
          property(property(device, 'configuration') as JSObject, 'interfaces'),
        )) {
          for (final alternate in objects(property(interface, 'alternates'))) {
            interfaces.add({
              'number': integer(property(interface, 'interfaceNumber')),
              'alternate': integer(property(alternate, 'alternateSetting')),
              'class': integer(property(alternate, 'interfaceClass')),
              'endpoints': [
                for (final endpoint in objects(
                  property(alternate, 'endpoints'),
                ))
                  {
                    'address':
                        integer(property(endpoint, 'endpointNumber')) |
                        (string(property(endpoint, 'direction')) == 'in'
                            ? 0x80
                            : 0),
                    'bulk': string(property(endpoint, 'type')) == 'bulk',
                  },
              ],
            });
          }
        }
        layout =
            jsonDecode(
                  string(
                    call(engine, 'usb_layout', [jsonEncode(interfaces).toJS]),
                  ),
                )
                as Map<String, dynamic>;
        session.layout = layout;
        send('descriptors', {'interfaces': interfaces, 'layout': layout});
        for (final number in {
          layout['interface'],
          layout['control'],
        }.whereType<int>()) {
          send('claiming', {'interface': number});
          try {
            await session.transfer(
              () => invoke(device, 'claimInterface', [number.toJS]),
            );
          } catch (error) {
            throw StateError(
              'Cannot claim USB interface $number. Try Connect via serial if the OS owns its CDC driver. $error',
            );
          }
          current();
        }
        if (layout['alternate'] != 0)
          await session.transfer(
            () => invoke(device, 'selectAlternateInterface', [
              (layout['interface'] as int).toJS,
              (layout['alternate'] as int).toJS,
            ]),
          );
        current();
        if (operation != null) session.timeoutMs = 10000;
        transport = session.bridge;
      }
      final firmware =
          operation != null && string(property(operation, 'kind')) == 'flash'
          ? property(operation, 'firmware') as JSObject
          : null;
      final JSAny? result;
      if (firmware != null) {
        result = await invoke(engine, 'flash_usb', [
          transport,
          jsonEncode(layout).toJS,
          agent,
          property(firmware, 'manifestBytes'),
          property(firmware, 'source'),
          property(firmware, 'observer'),
          property(firmware, 'allowPreloader'),
          property(firmware, 'verifyWrites'),
          property(operation!, 'rebootAfterSuccess'),
        ]);
      } else if (sink != null) {
        result = await invoke(engine, 'backup_usb', [
          transport,
          jsonEncode(layout).toJS,
          agent,
          sink,
          property(operation!, 'rebootAfterSuccess'),
        ]);
      } else {
        result = await invoke(engine, 'probe_usb', [
          transport,
          jsonEncode(layout).toJS,
        ]);
      }
      current();
      if (sink != null) await invoke(sink, 'finish');
      final decoded = jsonDecode(string(result)) as Map<String, dynamic>;
      outcome = {
        'event': 'result',
        if (operation == null) 'report': decoded else ...decoded,
        if (sink != null) 'backup_file': string(property(sink, 'filename')),
        'elapsed_ms': elapsed.elapsedMilliseconds,
      };
    } catch (error) {
      if (serial) _retired.add(device);
      await _abort(operation);
      outcome = {
        'event': 'error',
        'message': '$error',
        'elapsed_ms': elapsed.elapsedMilliseconds,
      };
    } finally {
      if (_usb?.timedOut == true ||
          _serial?.closed == true ||
          run != _generation)
        _retired.add(device);
      await _usb?.close();
      await _serial?.close();
      _usb = null;
      _serial = null;
      _busy = false;
      if (run == _generation) {
        _armed = false;
        _operation = null;
        if (outcome != null)
          emit({
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            if (serial) 'transport': 'webserial',
            ...outcome,
          });
      }
    }
  }

  @JSExport('watch')
  JSPromise<JSAny?> jsWatch() => watch().then<JSAny?>((_) => null).toJS;
  Future<void> watch() async {
    if (serial || api == null || _armed || _busy) return;
    final run = ++_generation;
    _armed = true;
    _timer = Timer(const Duration(seconds: 30), () {
      _armed = false;
      send('error', {
        'message': 'No authorized preloader appeared in 30 seconds.',
      });
    });
    send('waiting', {
      'message': 'Power off and reconnect the previously authorized Y2.',
    });
    try {
      final devices = objects(
        await invoke(api!, 'getDevices'),
      ).where(_candidate).toList();
      if (run != _generation) return;
      if (devices.length > 1)
        throw StateError(
          'Multiple authorized MediaTek devices. Connect only the intended Y2.',
        );
      if (devices.length == 1) await _capture(devices.single, null);
    } catch (error) {
      if (run == _generation) {
        _timer?.cancel();
        _armed = false;
        send('error', {'message': '$error'});
      }
    }
  }

  @JSExport('stop')
  JSPromise<JSAny?> jsStop() => stop().then<JSAny?>((_) => null).toJS;
  Future<void> stop() async {
    ++_generation;
    _armed = false;
    _timer?.cancel();
    _usb?.requestStop();
    _serial?.requestStop();
    await _abort(_operation);
    _operation = null;
    await _active;
  }
}
