import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'js.dart';

/// WebUSB adapter only. Rust continues to own all protocol and geometry policy.
class BrowserPort {
  BrowserPort(this.device, this.layout, {this.timeoutMs = 500})
    : cleanupTimeoutMs = timeoutMs;
  final JSObject device;
  Map<String, dynamic> layout;
  int timeoutMs;
  final int cleanupTimeoutMs;
  bool closed = false, timedOut = false, stopped = false;
  Uint8List _buffer = Uint8List(0);
  late final JSObject bridge = createJSInteropWrapper(this);

  Future<T> transfer<T>(Future<T> Function() action) async {
    if (closed)
      throw StateError('USB session closed; reconnect before retrying.');
    return action().timeout(
      Duration(milliseconds: timeoutMs),
      onTimeout: () {
        closed = true;
        timedOut = true;
        unawaited(ignoreFailure(invoke(device, 'close')));
        throw TimeoutException(
          'USB transfer timed out. Power off and reconnect.',
        );
      },
    );
  }

  @JSExport()
  void requestStop() {
    stopped = true;
  }

  @JSExport()
  void resumeForReset() {
    stopped = false;
  }

  @JSExport('read')
  JSPromise<JSUint8Array> jsRead(int length) =>
      read(length).then((bytes) => bytes.toJS).toJS;
  Future<Uint8List> read(int length) async {
    if (closed)
      throw StateError('USB session closed; reconnect before retrying.');
    if (stopped) throw StateError('Operation stopped');
    final elapsed = Stopwatch()..start();
    while (_buffer.isEmpty) {
      if (elapsed.elapsedMilliseconds >= timeoutMs)
        throw TimeoutException('USB read timed out after empty packets');
      var packetSize = 1024;
      final configuration = property(device, 'configuration') as JSObject?;
      if (configuration != null) {
        for (final interface in objects(
          property(configuration, 'interfaces'),
        )) {
          if (integer(property(interface, 'interfaceNumber')) !=
              layout['interface'])
            continue;
          for (final alternate in objects(property(interface, 'alternates'))) {
            if (integer(property(alternate, 'alternateSetting')) !=
                layout['alternate'])
              continue;
            for (final endpoint in objects(property(alternate, 'endpoints'))) {
              if (string(property(endpoint, 'direction')) == 'in' &&
                  integer(property(endpoint, 'endpointNumber')) ==
                      ((layout['input'] as int) & 0x7f))
                packetSize = integer(property(endpoint, 'packetSize'));
            }
          }
        }
      }
      final count =
          ((length.clamp(1, 65536) + packetSize - 1) ~/ packetSize) *
          packetSize;
      final result =
          await transfer(
                () => invoke(device, 'transferIn', [
                  ((layout['input'] as int) & 0x7f).toJS,
                  count.toJS,
                ]),
              )
              as JSObject;
      if (stopped) throw StateError('Operation stopped');
      final data = property(result, 'data') as JSDataView?;
      if (string(property(result, 'status')) != 'ok' || data == null)
        throw StateError('USB read failed');
      final view = data.toDart;
      _buffer = Uint8List.fromList(
        view.buffer.asUint8List(view.offsetInBytes, view.lengthInBytes),
      );
    }
    final count = length.clamp(0, _buffer.length);
    final result = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer = Uint8List.fromList(_buffer.sublist(count));
    return result;
  }

  @JSExport('write')
  JSPromise<JSAny?> jsWrite(JSUint8Array bytes) =>
      write(Uint8List.fromList(bytes.toDart)).then<JSAny?>((_) => null).toJS;
  Future<void> write(Uint8List bytes) async {
    final copy = Uint8List.fromList(bytes);
    final result =
        await transfer(
              () => invoke(device, 'transferOut', [
                ((layout['output'] as int) & 0x7f).toJS,
                copy.toJS,
              ]),
            )
            as JSObject;
    if (string(property(result, 'status')) != 'ok' ||
        integer(property(result, 'bytesWritten')) != copy.length)
      throw StateError('USB write failed or was short.');
  }

  @JSExport('control')
  JSPromise<JSAny?> jsControl(
    int request,
    int value,
    int index,
    JSUint8Array bytes,
  ) => control(
    request,
    value,
    index,
    Uint8List.fromList(bytes.toDart),
  ).then<JSAny?>((_) => null).toJS;
  Future<void> control(
    int request,
    int value,
    int index,
    Uint8List bytes,
  ) async {
    final copy = Uint8List.fromList(bytes);
    final result =
        await transfer(
              () => invoke(device, 'controlTransferOut', [
                object({
                  'requestType': 'class'.toJS,
                  'recipient': 'interface'.toJS,
                  'request': request.toJS,
                  'value': value.toJS,
                  'index': index.toJS,
                }),
                copy.toJS,
              ]),
            )
            as JSObject;
    if (string(property(result, 'status')) != 'ok' ||
        integer(property(result, 'bytesWritten')) != copy.length)
      throw StateError('USB CDC setup failed. Check the interface driver.');
  }

  Future<void> close() async {
    closed = true;
    await ignoreFailure(
      invoke(device, 'close').timeout(Duration(milliseconds: cleanupTimeoutMs)),
    );
  }
}

/// Web Serial keeps the OS CDC driver; the same Rust byte protocol is used.
class SerialTransport {
  SerialTransport(
    this.port, {
    this.timeoutMs = 500,
    void Function(Map<String, dynamic>)? trace,
  }) : cleanupTimeoutMs = timeoutMs,
       trace = trace ?? ((_) {});
  final JSObject port;
  int timeoutMs;
  final int cleanupTimeoutMs;
  final void Function(Map<String, dynamic>) trace;
  bool closed = false, stopped = false;
  JSObject? _reader, _writer;
  Uint8List _buffer = Uint8List(0);
  Future<void>? _closing;
  late final JSObject bridge = createJSInteropWrapper(this);
  Future<T> bounded<T>(Future<T> Function() action, String stage) async {
    if (closed)
      throw StateError('Serial session closed. Power off and reconnect.');
    final elapsed = Stopwatch()..start();
    trace({'stage': stage, 'state': 'started'});
    try {
      final result = await action().timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () {
          unawaited(close());
          throw TimeoutException('$stage timed out. Power off and reconnect.');
        },
      );
      trace({
        'stage': stage,
        'state': 'completed',
        'elapsed_ms': elapsed.elapsedMilliseconds,
      });
      return result;
    } catch (error) {
      trace({
        'stage': stage,
        'state': 'failed',
        'message': '$error',
        'elapsed_ms': elapsed.elapsedMilliseconds,
      });
      rethrow;
    }
  }

  Future<void> open() async {
    await bounded(() async {
      await invoke(port, 'open', [
        {
          'baudRate': 921600,
          'dataBits': 8,
          'stopBits': 1,
          'parity': 'none',
          'flowControl': 'none',
          'bufferSize': 4096,
        }.jsify(),
      ]);
      if (closed) {
        await ignoreFailure(invoke(port, 'close'));
        throw StateError('Serial open cancelled');
      }
    }, 'serial-open');
    _reader =
        call(property(port, 'readable') as JSObject, 'getReader') as JSObject;
    _writer =
        call(property(port, 'writable') as JSObject, 'getWriter') as JSObject;
    await bounded(
      () => invoke(port, 'setSignals', [
        {'requestToSend': true, 'dataTerminalReady': false}.jsify(),
      ]),
      'serial-signals',
    );
  }

  @JSExport()
  void requestStop() {
    stopped = true;
  }

  @JSExport()
  void resumeForReset() {
    stopped = false;
  }

  @JSExport('read')
  JSPromise<JSUint8Array> jsRead(int length) =>
      read(length).then((bytes) => bytes.toJS).toJS;
  Future<Uint8List> read(int length) async {
    if (closed) throw StateError('Serial session closed');
    if (stopped) throw StateError('Operation stopped');
    if (_buffer.isEmpty) {
      final result =
          await bounded(() => invoke(_reader!, 'read'), 'serial-read')
              as JSObject;
      if (stopped) throw StateError('Operation stopped');
      final value = property(result, 'value') as JSUint8Array?;
      if (boolean(property(result, 'done')) ||
          value == null ||
          value.toDart.isEmpty)
        throw StateError('Serial port disconnected or returned no data.');
      _buffer = Uint8List.fromList(value.toDart);
    }
    final count = length.clamp(0, _buffer.length);
    final result = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer = Uint8List.fromList(_buffer.sublist(count));
    return result;
  }

  @JSExport('write')
  JSPromise<JSAny?> jsWrite(JSUint8Array bytes) =>
      write(Uint8List.fromList(bytes.toDart)).then<JSAny?>((_) => null).toJS;
  Future<void> write(Uint8List bytes) async {
    final copy = Uint8List.fromList(bytes);
    await bounded(() => invoke(_writer!, 'write', [copy.toJS]), 'serial-write');
  }

  @JSExport('control')
  JSPromise<JSAny?> jsControl(
    int request,
    int value,
    int index,
    JSUint8Array bytes,
  ) => Future<JSAny?>.error(
    StateError('Unexpected raw USB control request on serial transport'),
  ).toJS;
  Future<void> close() {
    closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    final cleanup = () async {
      await Future.wait([
        if (_reader != null) ignoreFailure(invoke(_reader!, 'cancel')),
        if (_writer != null) ignoreFailure(invoke(_writer!, 'abort')),
      ]);
      if (_reader != null) call(_reader!, 'releaseLock');
      if (_writer != null) call(_writer!, 'releaseLock');
      await ignoreFailure(invoke(port, 'close'));
    }();
    await ignoreFailure(
      cleanup.timeout(Duration(milliseconds: cleanupTimeoutMs)),
    );
  }
}
