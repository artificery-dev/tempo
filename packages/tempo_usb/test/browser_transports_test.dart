@TestOn('node')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:tempo_usb/src/browser/js.dart';
import 'package:tempo_usb/src/browser/transports.dart';

JSPromise<JSAny?> done([JSAny? result]) => Future<JSAny?>.value(result).toJS;
void main() {
  const layout = {
    'input': 0x81,
    'output': 2,
    'interface': 1,
    'alternate': 0,
    'control': null,
  };
  test('timed out USB read closes and poisons the port', () async {
    var closed = false, wrote = false;
    final port = BrowserPort(
      object({
        'transferIn':
            ((int endpoint, int length) => Completer<JSAny?>().future.toJS)
                .toJS,
        'close': (() {
          closed = true;
          return done();
        }).toJS,
        'transferOut': ((int endpoint, JSUint8Array bytes) {
          wrote = true;
          return done();
        }).toJS,
      }),
      layout,
      timeoutMs: 5,
    );
    await expectLater(port.read(1), throwsA(isA<TimeoutException>()));
    await expectLater(port.write(Uint8List.fromList([1])), throwsStateError);
    expect(closed, isTrue);
    expect(wrote, isFalse);
  });
  test(
    'short USB writes are rejected; cooperative cancellation allows reset',
    () async {
      var short = true;
      final writes = <List<int>>[];
      final port = BrowserPort(
        object({
          'transferOut': ((int endpoint, JSUint8Array bytes) {
            writes.add(bytes.toDart.toList());
            return done(
              {
                'status': 'ok',
                'bytesWritten': short ? 0 : bytes.toDart.length,
              }.jsify(),
            );
          }).toJS,
          'close': (() => done()).toJS,
        }),
        layout,
      );
      await expectLater(port.write(Uint8List.fromList([1])), throwsStateError);
      port.requestStop();
      await expectLater(port.read(1), throwsStateError);
      port.resumeForReset();
      short = false;
      await port.write(Uint8List.fromList([0xdb, 0, 0xc0]));
      expect(writes.last, [0xdb, 0, 0xc0]);
      await port.close();
    },
  );
  test('WebUSB read keeps excess bytes and copies DataView slices', () async {
    final data = Uint8List.fromList([99, 1, 2, 3, 99]);
    var reads = 0;
    final port = BrowserPort(
      object({
        'transferIn': ((int endpoint, int length) {
          reads++;
          return done(
            object({
              'status': 'ok'.toJS,
              'data': ByteData.sublistView(data, 1, 4).toJS,
            }),
          );
        }).toJS,
        'close': (() => done()).toJS,
      }),
      layout,
    );
    expect(await port.read(1), [1]);
    expect(await port.read(2), [2, 3]);
    expect(reads, 1);
  });
  test('serial retains excess bytes and closes its stream locks', () async {
    var released = 0;
    final reader = object({
      'read': (() => done(
        object({
          'done': false.toJS,
          'value': Uint8List.fromList([1, 2, 3]).toJS,
        }),
      )).toJS,
      'cancel': (() => done()).toJS,
      'releaseLock': (() {
        released++;
      }).toJS,
    });
    final writer = object({
      'write': ((JSUint8Array bytes) => done()).toJS,
      'abort': (() => done()).toJS,
      'releaseLock': (() {
        released++;
      }).toJS,
    });
    final port = SerialTransport(
      object({
        'open': ((JSObject options) => done()).toJS,
        'close': (() => done()).toJS,
        'setSignals': ((JSObject options) => done()).toJS,
        'readable': object({'getReader': (() => reader).toJS}),
        'writable': object({'getWriter': (() => writer).toJS}),
      }),
    );
    await port.open();
    expect(await port.read(1), [1]);
    expect(await port.read(2), [2, 3]);
    await port.close();
    expect(released, 2);
  });
}
