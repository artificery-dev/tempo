@TestOn('node')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:tempo_usb/src/browser/js.dart';
import 'package:tempo_usb/src/browser/transports.dart';

@JS('Function')
extension type JsFunction._(JSFunction _) implements JSFunction {
  external JsFunction(JSString body);
}
JSPromise<JSAny?> done([JSAny? result]) => Future<JSAny?>.value(result).toJS;
void main() {
  test(
    'production Rust Wasm probes through compiled Dart WebUSB adapter',
    () async {
      final loader = JsFunction(
        'return (async()=>{const p=process.cwd()+"/../../toolbox/app/web/pkg/tempo_installer";const e=await import("file://"+p+".js");const fs=await import("node:fs/promises");e.initSync({module:await fs.readFile(p+"_bg.wasm")});return e;})();'
            .toJS,
      );
      final engine =
          await (loader.callAsFunction() as JSPromise<JSObject>).toDart;
      final layout = {
        'interface': 1,
        'alternate': 0,
        'input': 0x81,
        'output': 2,
        'control': 0,
      };
      final reads = <List<int>>[
        [0x5f],
        [0xf5],
        [0xaf],
        [0xfa],
        [0xfd],
        [0x65],
        [0x82, 0, 0],
        [0xfc],
        [0x8a, 0, 0xca, 1, 0, 1, 0, 0],
      ];
      final writes = <List<int>>[], controls = <int>[];
      final port = BrowserPort(
        object({
          'transferIn': ((int endpoint, int length) {
            if (endpoint != 1) throw StateError("Wrong endpoint");
            return done(
              object({
                'status': 'ok'.toJS,
                'data': ByteData.sublistView(
                  Uint8List.fromList(reads.removeAt(0)),
                ).toJS,
              }),
            );
          }).toJS,
          'transferOut': ((int endpoint, JSUint8Array bytes) {
            writes.add(bytes.toDart.toList());
            return done(
              {'status': 'ok', 'bytesWritten': bytes.toDart.length}.jsify(),
            );
          }).toJS,
          'controlTransferOut': ((JSObject setup, JSUint8Array bytes) {
            controls.add(integer(property(setup, 'request')));
            return done(
              {'status': 'ok', 'bytesWritten': bytes.toDart.length}.jsify(),
            );
          }).toJS,
        }),
        layout,
      );
      final report =
          jsonDecode(
                string(
                  await invoke(engine, 'probe_usb', [
                    port.bridge,
                    jsonEncode(layout).toJS,
                  ]),
                ),
              )
              as Map<String, dynamic>;
      expect(report['hardware_code'], 0x6582);
      expect(report['storage_written'], false);
      expect(writes, [
        [0xa0],
        [0x0a],
        [0x50],
        [5],
        [0xfd],
        [0xfc],
      ]);
      expect(controls, [0x20, 0x22]);
    },
  );
  test(
    'production Wasm serial retries buffered READY after a poll delay',
    () async {
      final loader = JsFunction(
        'return (async()=>{const p=process.cwd()+"/../../toolbox/app/web/pkg/tempo_installer";const e=await import("file://"+p+".js");const fs=await import("node:fs/promises");e.initSync({module:await fs.readFile(p+"_bg.wasm")});return e;})();'
            .toJS,
      );
      final engine =
          await (loader.callAsFunction() as JSPromise<JSObject>).toDart;
      final responses = <List<int>>[
        utf8.encode('READY' * 7),
        [0x5f],
        [0xf5],
        [0xaf],
        [0xfa],
        [0xfd, 0x65, 0x82, 0, 0],
        [0xfc, 0x8a, 0, 0xca, 1, 0, 1, 0, 0],
      ];
      final writes = <List<int>>[];
      final times = <int>[];
      final elapsed = Stopwatch()..start();
      List<int>? incoming;
      final reader = object({
        'read': (() => done(
          object({
            'done': false.toJS,
            'value': Uint8List.fromList(incoming!).toJS,
          }),
        )).toJS,
        'cancel': (() => done()).toJS,
        'releaseLock': (() {}).toJS,
      });
      final writer = object({
        'write': ((JSUint8Array bytes) {
          writes.add(bytes.toDart.toList());
          times.add(elapsed.elapsedMilliseconds);
          incoming = responses.removeAt(0);
          return done();
        }).toJS,
        'abort': (() => done()).toJS,
        'releaseLock': (() {}).toJS,
      });
      final port = SerialTransport(
        object({
          'open': ((JSObject options) => done()).toJS,
          'setSignals': ((JSObject options) => done()).toJS,
          'close': (() => done()).toJS,
          'readable': object({'getReader': (() => reader).toJS}),
          'writable': object({'getWriter': (() => writer).toJS}),
        }),
      );
      await port.open();
      final report =
          jsonDecode(
                string(
                  await invoke(engine, 'probe_usb', [
                    port.bridge,
                    jsonEncode({
                      'interface': 0,
                      'alternate': 0,
                      'input': 0,
                      'output': 0,
                      'control': null,
                    }).toJS,
                  ]),
                ),
              )
              as Map<String, dynamic>;
      expect(report['hardware_code'], 0x6582);
      expect(writes, [
        [0xa0],
        [0xa0],
        [0x0a],
        [0x50],
        [5],
        [0xfd],
        [0xfc],
      ]);
      expect(times[1] - times[0], greaterThanOrEqualTo(20));
      await port.close();
    },
  );
}
