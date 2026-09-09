import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'archive.dart';
import 'js.dart';

@JS('navigator')
external JSObject get navigator;
@JS('window')
external JSObject get window;
@JS('document')
external JSObject get document;
@JS('URL.createObjectURL')
external JSString createUrl(JSObject file);
@JS('URL.revokeObjectURL')
external void revokeUrl(JSString url);
@JS('CompressionStream')
extension type Compression._(JSObject _) implements JSObject {
  external Compression(JSString format);
}
@JS('DecompressionStream')
extension type Decompression._(JSObject _) implements JSObject {
  external Decompression(JSString format);
}

class BrowserFile implements ArchiveFile {
  BrowserFile(this.file);
  final JSObject file;
  int get size => integer(property(file, 'size'));
  Future<Uint8List> read(int offset, int length) async =>
      (await invoke(
                call(file, 'slice', [offset.toJS, (offset + length).toJS])
                    as JSObject,
                'arrayBuffer',
              )
              as JSArrayBuffer)
          .toDart
          .asUint8List();
}

Future<JSObject> pickFirmware() async {
  if (property(window, 'showOpenFilePicker') != null) {
    final handles = objects(
      await invoke(window, 'showOpenFilePicker', [
        {
          'multiple': false,
          'types': [
            {
              'description': 'Tempo Y2 firmware',
              'accept': {
                'application/zip': ['.y2-firmware'],
              },
            },
          ],
        }.jsify(),
      ]),
    );
    return await invoke(handles.single, 'getFile') as JSObject;
  }
  final input = call(document, 'createElement', ['input'.toJS]) as JSObject;
  input.setProperty('type'.toJS, 'file'.toJS);
  input.setProperty('accept'.toJS, '.y2-firmware'.toJS);
  final done = Completer<JSObject>();
  input.setProperty(
    'onchange'.toJS,
    (() {
      final files = property(input, 'files') as JSObject;
      if (integer(property(files, 'length')) == 0) {
        done.completeError(StateError('No firmware package selected.'));
      } else {
        done.complete(files.getProperty<JSObject>(0.toJS));
      }
    }).toJS,
  );
  input.setProperty(
    'oncancel'.toJS,
    (() {
      if (!done.isCompleted)
        done.completeError(StateError('No firmware package selected.'));
    }).toJS,
  );
  call(input, 'click');
  return done.future;
}

JSObject entryReader(JSObject file, ArchiveEntry entry) {
  var stream =
      call(
            call(file, 'slice', [
                  entry.dataStart.toJS,
                  (entry.dataStart + entry.compressedSize).toJS,
                ])
                as JSObject,
            'stream',
          )
          as JSObject;
  if (entry.method == 8)
    stream =
        call(stream, 'pipeThrough', [Decompression('deflate-raw'.toJS)])
            as JSObject;
  return call(stream, 'getReader') as JSObject;
}

Future<void> streamEntry(
  JSObject file,
  ArchiveEntry entry,
  Future<void> Function(JSUint8Array) consume,
) async {
  final reader = entryReader(file, entry);
  var count = 0;
  try {
    while (true) {
      final result = await invoke(reader, 'read') as JSObject;
      if (boolean(property(result, 'done'))) break;
      final bytes = property(result, 'value') as JSUint8Array;
      count += bytes.toDart.length;
      if (count > entry.size)
        throw FormatException('${entry.name} expands beyond declared size.');
      await consume(bytes);
    }
    if (count != entry.size)
      throw FormatException('Size mismatch for ${entry.name}.');
  } finally {
    await ignoreFailure(invoke(reader, 'cancel'));
    call(reader, 'releaseLock');
  }
}

class BrowserFirmwareSource {
  BrowserFirmwareSource(this.files);
  final List<JSObject> files;
  late final JSObject bridge = createJSInteropWrapper(this);
  @JSExport('readChunk')
  JSPromise<JSUint8Array> readChunk(int image, int offset, int length) =>
      _read(image, offset, length).then((v) => v.toJS).toJS;
  Future<Uint8List> _read(int image, int offset, int length) async {
    if (image < 0 ||
        image >= files.length ||
        offset < 0 ||
        length < 0 ||
        offset + length > integer(property(files[image], 'size')))
      throw RangeError('Firmware source range is unavailable.');
    return BrowserFile(files[image]).read(offset, length);
  }
}

class FirmwareDestination {
  FirmwareDestination(this.engine, this.emit);
  final JSObject engine;
  final void Function(Map<String, dynamic>) emit;
  JSObject? prepared, _storage;
  String? _rootName;
  Future<Map<String, dynamic>> prepare() async {
    // Start picker before asynchronous cleanup to retain transient user activation.
    final picking = pickFirmware();
    await clear();
    final file = await picking;
    final filename = string(property(file, 'name'));
    if (!filename.endsWith('.y2-firmware'))
      throw const FormatException('Choose a .y2-firmware package.');
    final entries = await parseArchive(BrowserFile(file));
    if (entries.first.name != 'manifest.json' ||
        entries.first.size > 1024 * 1024)
      throw const FormatException(
        'manifest.json must be first and at most 1 MiB.',
      );
    final manifest = BytesBuilder(copy: false);
    await streamEntry(file, entries.first, (bytes) async {
      manifest.add(bytes.toDart);
    });
    final manifestBytes = manifest.takeBytes().toJS;
    final data =
        jsonDecode(string(call(engine, 'inspect_firmware', [manifestBytes])))
            as Map<String, dynamic>;
    final images = (data['images'] as List).cast<Map<String, dynamic>>();
    final expected = images.map((i) => i['file']).toSet();
    if (entries.length != expected.length + 1 ||
        entries.skip(1).any((e) => !expected.contains(e.name)))
      throw const FormatException('Missing or unreferenced firmware entries.');
    for (final image in images) {
      if (entries.singleWhere((e) => e.name == image['file']).size !=
          image['size'])
        throw const FormatException('Firmware entry size mismatch.');
    }
    final total = images.fold<int>(0, (sum, i) => sum + (i['size'] as int));
    final storage = property(navigator, 'storage') as JSObject?;
    if (storage == null || property(storage, 'getDirectory') == null)
      throw StateError(
        'Temporary browser storage is unavailable. Use the native Toolbox.',
      );
    if (property(storage, 'estimate') != null) {
      final estimate = await invoke(storage, 'estimate') as JSObject;
      final quota = property(estimate, 'quota');
      if (quota != null &&
          integer(quota) -
                  (property(estimate, 'usage') == null
                      ? 0
                      : integer(property(estimate, 'usage'))) <
              total + 64 * 1024 * 1024)
        throw StateError('Insufficient temporary browser storage.');
    }
    final root = await invoke(storage, 'getDirectory') as JSObject;
    final rootName = 'tempo-firmware-${DateTime.now().microsecondsSinceEpoch}';
    final directory =
        await invoke(root, 'getDirectoryHandle', [
              rootName.toJS,
              {'create': true}.jsify(),
            ])
            as JSObject;
    var completed = 0;
    final files = <JSObject>[];
    try {
      emit({
        'event': 'firmware-prepare-started',
        'completed': 0,
        'total': total,
      });
      for (var i = 0; i < images.length; i++) {
        final entry = entries.singleWhere((e) => e.name == images[i]['file']);
        final handle =
            await invoke(directory, 'getFileHandle', [
                  'image-$i.bin'.toJS,
                  {'create': true}.jsify(),
                ])
                as JSObject;
        final writer = await invoke(handle, 'createWritable') as JSObject;
        try {
          await streamEntry(file, entry, (bytes) async {
            await invoke(writer, 'write', [bytes]);
            completed += bytes.toDart.length;
            emit({
              'event': 'firmware-prepare-progress',
              'completed': completed,
              'total': total,
              'image': entry.name,
            });
          });
          await invoke(writer, 'close');
        } catch (error) {
          await ignoreFailure(invoke(writer, 'abort', ['$error'.toJS]));
          rethrow;
        }
        files.add(await invoke(handle, 'getFile') as JSObject);
      }
      final source = BrowserFirmwareSource(files);
      JSObject observer(String event) => object({
        'progress': ((JSString json) {
          emit({
            'event': event,
            ...jsonDecode(json.toDart) as Map<String, dynamic>,
          });
        }).toJS,
      });
      final info =
          jsonDecode(
                string(
                  await invoke(engine, 'verify_firmware', [
                    manifestBytes,
                    source.bridge,
                    observer('firmware-verify-progress'),
                  ]),
                ),
              )
              as Map<String, dynamic>;
      prepared = object({
        'manifestBytes': manifestBytes,
        'source': source.bridge,
        'observer': observer('flash-progress'),
      });
      _storage = root;
      _rootName = rootName;
      emit({
        'event': 'firmware-ready',
        'firmware': info['firmware'],
        'message': 'Firmware package verified and ready.',
      });
      return {'ready': true, 'filename': filename, ...info};
    } catch (_) {
      await ignoreFailure(
        invoke(root, 'removeEntry', [
          rootName.toJS,
          {'recursive': true}.jsify(),
        ]),
      );
      rethrow;
    }
  }

  JSObject take(bool allowPreloader, {bool verifyWrites = true}) {
    final value = prepared;
    if (value == null)
      throw StateError('Choose and verify a firmware package first.');
    value.setProperty('allowPreloader'.toJS, allowPreloader.toJS);
    value.setProperty('verifyWrites'.toJS, verifyWrites.toJS);
    return value;
  }

  Future<void> clear() async {
    prepared = null;
    final storage = _storage, name = _rootName;
    _storage = null;
    _rootName = null;
    if (storage != null && name != null)
      await ignoreFailure(
        invoke(storage, 'removeEntry', [
          name.toJS,
          {'recursive': true}.jsify(),
        ]),
      );
  }
}

class BackupSink {
  BackupSink(
    this.filename,
    JSObject output,
    this.emit, {
    this.root,
    this.handle,
  }) {
    final gzip = Compression('gzip'.toJS);
    writer =
        call(property(gzip, 'writable') as JSObject, 'getWriter') as JSObject;
    pump = invoke(property(gzip, 'readable') as JSObject, 'pipeTo', [output]);
    unawaited(ignoreFailure(pump));
  }
  @JSExport()
  final String filename;
  final JSObject? root, handle;
  final void Function(Map<String, dynamic>) emit;
  late final JSObject writer;
  late final Future<JSAny?> pump;
  bool settled = false;
  late final JSObject bridge = createJSInteropWrapper(this);
  @JSExport()
  void start(int total) => emit({
    'event': 'backup-started',
    'completed': 0,
    'total': total,
    'format': 'raw-emmc-gzip',
  });
  @JSExport('writeChunk')
  JSPromise<JSAny?> writeChunk(JSUint8Array bytes, int completed, int total) {
    final copy = Uint8List.fromList(bytes.toDart).toJS;
    return _write(copy, completed, total).then<JSAny?>((_) => null).toJS;
  }

  Future<void> _write(JSUint8Array bytes, int completed, int total) async {
    if (settled) throw StateError('Backup destination is closed.');
    await invoke(writer, 'write', [bytes]);
    emit({'event': 'progress', 'completed': completed, 'total': total});
  }

  @JSExport('finish')
  JSPromise<JSAny?> jsFinish() => finish().then<JSAny?>((_) => null).toJS;
  Future<void> finish() async {
    if (settled) return;
    await invoke(writer, 'close');
    await pump;
    settled = true;
    if (handle != null) {
      final file = await invoke(handle!, 'getFile') as JSObject;
      final url = createUrl(file);
      final anchor = call(document, 'createElement', ['a'.toJS]) as JSObject;
      anchor.setProperty('href'.toJS, url);
      anchor.setProperty('download'.toJS, filename.toJS);
      call(anchor, 'click');
      Timer(const Duration(seconds: 60), () {
        revokeUrl(url);
        if (root != null)
          unawaited(
            ignoreFailure(invoke(root!, 'removeEntry', [filename.toJS])),
          );
      });
    }
  }

  @JSExport('abort')
  JSPromise<JSAny?> jsAbort(JSAny? reason) =>
      abort().then<JSAny?>((_) => null).toJS;
  Future<void> abort() async {
    if (settled) return;
    settled = true;
    await ignoreFailure(invoke(writer, 'abort', ['Cancelled'.toJS]));
    await ignoreFailure(pump);
    if (root != null)
      await ignoreFailure(invoke(root!, 'removeEntry', [filename.toJS]));
  }
}

class BackupDestination {
  BackupDestination(this.emit);
  final void Function(Map<String, dynamic>) emit;
  BackupSink? prepared;
  Future<Map<String, dynamic>> prepare() async {
    await clear();
    final name =
        'innioasis-y2-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}-emmc.img.gz';
    final storage = property(navigator, 'storage') as JSObject?;
    var temporary =
        storage != null && property(storage, 'getDirectory') != null;
    if (temporary && property(storage, 'estimate') != null) {
      final estimate = await invoke(storage, 'estimate') as JSObject;
      final quota = property(estimate, 'quota');
      if (quota != null &&
          integer(quota) -
                  (property(estimate, 'usage') == null
                      ? 0
                      : integer(property(estimate, 'usage'))) <
              0x1d2880000 + 0x4000000)
        temporary = false;
    }
    final JSObject handle;
    JSObject? root;
    if (temporary) {
      root = await invoke(storage!, 'getDirectory') as JSObject;
      handle =
          await invoke(root, 'getFileHandle', [
                name.toJS,
                {'create': true}.jsify(),
              ])
              as JSObject;
    } else {
      if (property(window, 'showSaveFilePicker') == null)
        throw StateError(
          'Free at least 8 GB of browser storage or use the native Toolbox.',
        );
      handle =
          await invoke(window, 'showSaveFilePicker', [
                {
                  'suggestedName': name,
                  'types': [
                    {
                      'description': 'Compressed Y2 eMMC image',
                      'accept': {
                        'application/gzip': ['.gz'],
                      },
                    },
                  ],
                }.jsify(),
              ])
              as JSObject;
    }
    final filename = property(handle, 'name') == null
        ? name
        : string(property(handle, 'name'));
    final output = await invoke(handle, 'createWritable') as JSObject;
    try {
      prepared = BackupSink(
        filename,
        output,
        emit,
        root: root,
        handle: temporary ? handle : null,
      );
    } catch (_) {
      await ignoreFailure(invoke(output, 'abort'));
      if (root != null)
        await ignoreFailure(invoke(root, 'removeEntry', [filename.toJS]));
      rethrow;
    }
    return {
      'ready': true,
      'filename': filename,
      'temporary_browser_storage': temporary,
      'automatic_download': temporary,
    };
  }

  JSObject take() {
    final value = prepared;
    prepared = null;
    if (value == null) throw StateError('Backup storage is not ready yet.');
    return value.bridge;
  }

  Future<void> clear() async {
    final value = prepared;
    prepared = null;
    await value?.abort();
  }
}
