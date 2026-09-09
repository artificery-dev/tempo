import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _StartNative =
    Pointer<Void> Function(Pointer<Utf8>, Int32, Pointer<Utf8>, UintPtr);
typedef _StartDart =
    Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Utf8>, int);

/// Diagnostic-only bridge to daemon/native. Dart never dereferences handles.
///
/// Do not embed this runtime in a host that starts Dart subprocesses. The Linux
/// Dart VM reaps any child with wait(), competing with Rust std::process and
/// losing native child exit statuses. Production runs the native broker in a
/// separate process and uses its Unix API.
final class NativeControl {
  NativeControl._(this.libraryPath, this._address);
  final String libraryPath;
  int _address;
  Future<void>? _closing;

  static NativeControl start({
    required String libraryPath,
    required String socketPath,
    int activatedFd = -1,
  }) {
    if (socketPath.contains('\u0000')) {
      throw ArgumentError('Socket path cannot contain NUL.');
    }
    final library = DynamicLibrary.open(libraryPath);
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'tempod_native_abi_version',
    )();
    if (version != 1) {
      throw StateError('Unsupported native daemon ABI: $version');
    }
    final start = library.lookupFunction<_StartNative, _StartDart>(
      'tempod_native_start',
    );
    final path = socketPath.toNativeUtf8();
    final error = calloc<Uint8>(1024);
    try {
      final handle = start(path, activatedFd, error.cast(), 1024);
      if (handle == nullptr) {
        throw StateError(
          'Native control startup: ${error.cast<Utf8>().toDartString()}',
        );
      }
      return NativeControl._(libraryPath, handle.address);
    } finally {
      calloc.free(path);
      calloc.free(error);
    }
  }

  /// Existing handlers can block on device I/O. Joining them never blocks the
  /// main Dart isolate. Stop consumes the handle exactly once.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    final address = _address;
    _address = 0;
    final path = libraryPath;
    await Isolate.run(() => _stop(path, address));
  }
}

void _stop(String path, int address) {
  final library = DynamicLibrary.open(path);
  final stop = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('tempod_native_stop');
  stop(Pointer<Void>.fromAddress(address));
}
