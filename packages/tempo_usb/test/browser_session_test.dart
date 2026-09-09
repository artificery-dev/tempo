@TestOn('node')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:tempo_usb/src/browser/session.dart';
import 'package:tempo_usb/src/browser/js.dart';

JSPromise<JSAny?> done([JSAny? result]) => Future<JSAny?>.value(result).toJS;
void main() {
  test(
    'permission is synchronous and cancelled selection never opens device',
    () async {
      var requested = false, opened = false;
      final chooser = Completer<JSAny?>();
      final api = object({
        'addEventListener': ((JSString name, JSFunction callback) {}).toJS,
        'requestDevice': ((JSObject options) {
          requested = true;
          return chooser.future.toJS;
        }).toJS,
      });
      final session = BrowserSession(
        api: api,
        engine: JSObject(),
        agent: Uint8List(0).toJS,
        serial: false,
        emit: (_) {},
      );
      final choosing = session.choose();
      expect(requested, isTrue);
      await session.stop();
      chooser.complete(
        object({
          'vendorId': 0xe8d.toJS,
          'productId': 0x2000.toJS,
          'open': (() {
            opened = true;
            return done();
          }).toJS,
        }),
      );
      await choosing;
      expect(opened, isFalse);
    },
  );
  test('watch refuses ambiguous devices before opening', () async {
    final events = <Map<String, dynamic>>[];
    final device = {'vendorId': 0xe8d, 'productId': 0x2000}.jsify();
    final api = object({
      'addEventListener': ((JSString name, JSFunction callback) {}).toJS,
      'getDevices': (() => done([device, device].toJS)).toJS,
    });
    final session = BrowserSession(
      api: api,
      engine: JSObject(),
      agent: Uint8List(0).toJS,
      serial: false,
      emit: events.add,
    );
    await session.watch();
    expect(events.last['event'], 'error');
    expect(events.last['message'], contains('Multiple'));
    await session.stop();
  });
  test('cancelled backup chooser aborts prepared output', () async {
    final chooser = Completer<JSAny?>();
    var aborted = 0;
    final api = object({
      'addEventListener': ((JSString name, JSFunction callback) {}).toJS,
      'requestPort': ((JSObject options) => chooser.future.toJS).toJS,
    });
    final session = BrowserSession(
      api: api,
      engine: JSObject(),
      agent: Uint8List(0).toJS,
      serial: true,
      emit: (_) {},
    );
    final choosing = session.choose(
      object({
        'kind': 'backup'.toJS,
        'sink': object({
          'abort': ((JSAny? reason) {
            aborted++;
            return done();
          }).toJS,
        }),
      }),
    );
    await session.stop();
    expect(aborted, 1);
    chooser.complete(JSObject());
    await choosing;
    expect(aborted, 2);
  });
}
