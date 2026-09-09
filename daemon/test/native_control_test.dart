import 'dart:convert';
import 'dart:io';

import 'package:tempod/src/native/native_control.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['TEMPOD_TEST_NATIVE_LIBRARY'];
  test(
    'Dart loads the Rust core, preserves Unix ping, and stops it',
    () async {
      final directory = await Directory.systemTemp.createTemp('tempod-native-');
      final path = '${directory.path}/control.sock';
      final native = NativeControl.start(
        libraryPath: library!,
        socketPath: path,
      );
      try {
        final socket = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        socket.write('{"op":"ping"}\n');
        final reply = jsonDecode(
          await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
        );
        socket.destroy();
        expect(reply['ok'], isTrue);
        expect(reply['version'], isNotEmpty);
        expect(
          () => NativeControl.start(libraryPath: library, socketPath: path),
          throwsStateError,
        );
      } finally {
        await native.close();
        await native.close();
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set TEMPOD_TEST_NATIVE_LIBRARY to a built native core.'
        : false,
  );
}
