@TestOn('node')
library;

import 'dart:js_interop';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:tempo_usb/src/browser/storage.dart';
import 'package:tempo_usb/src/browser/js.dart';

@JS('WritableStream')
extension type Writable._(JSObject _) implements JSObject {
  external Writable(JSObject sink);
}
@JS('Blob')
extension type Blob._(JSObject _) implements JSObject {
  external Blob(JSArray<JSAny?> parts);
}
void main() {
  test('firmware source validates ranges and returns exact chunks', () async {
    final file = Blob(
      [
        Uint8List.fromList([1, 2, 3, 4]).toJS,
      ].toJS,
    );
    final source = BrowserFirmwareSource([file]);
    expect((await source.readChunk(0, 1, 2).toDart).toDart, [2, 3]);
    await expectLater(source.readChunk(0, -1, 1).toDart, throwsA(anything));
    await expectLater(source.readChunk(1, 0, 1).toDart, throwsA(anything));
    await expectLater(source.readChunk(0, 3, 2).toDart, throwsA(anything));
  });
  test(
    'backup copies input before asynchronous gzip and finishes output',
    () async {
      final chunks = <int>[];
      var closed = false;
      final output = Writable(
        object({
          'write': ((JSUint8Array bytes) {
            chunks.addAll(bytes.toDart);
          }).toJS,
          'close': (() {
            closed = true;
          }).toJS,
        }),
      );
      final events = <Map<String, dynamic>>[];
      final sink = BackupSink('test.gz', output, events.add);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final writing = sink.writeChunk(bytes.toJS, 3, 3).toDart;
      bytes.fillRange(0, 3, 9);
      await writing;
      await sink.finish();
      expect(closed, isTrue);
      expect(chunks.take(2), [0x1f, 0x8b]);
      expect(events.single['completed'], 3);
      await expectLater(
        sink.writeChunk(bytes.toJS, 3, 3).toDart,
        throwsA(anything),
      );
    },
  );
}
