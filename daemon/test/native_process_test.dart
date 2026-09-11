import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// No device services are contacted: wpctl/pw-dump are private fixtures.
void main() {
  final executable = Platform.environment['TEMPOD_TEST_NATIVE_EXECUTABLE'];
  test(
    'separate native broker retains child statuses alongside Dart children',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tempo-native-process-',
      );
      final path = '${directory.path}/control.sock';
      final fixtures = await Directory('${directory.path}/bin').create();
      Future<void> fixture(String name, String content) async {
        final file = File('${fixtures.path}/$name');
        await file.writeAsString(content);
        final result = await Process.run('/bin/chmod', ['700', file.path]);
        expect(result.exitCode, 0);
      }

      await fixture(
        'wpctl',
        '#!/bin/sh\n/bin/sleep 0.01\nprintf "Volume: 0.50\\n"\n',
      );
      await fixture('pw-dump', '#!/bin/sh\nprintf "[]\\n"\n');
      Process? native;
      Process? dartChild;
      StreamSubscription<List<int>>? output, errors;
      final diagnostics = StringBuffer();
      try {
        native = await Process.start(
          executable!,
          ['--no-sampler', '--socket', path],
          environment: {
            'PATH':
                '${fixtures.path}:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
          },
        );
        output = native.stdout.listen((_) {});
        errors = native.stderr.listen((bytes) {
          if (diagnostics.length < 16384) {
            diagnostics.write(utf8.decode(bytes, allowMalformed: true));
          }
        });
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (await FileSystemEntity.type(path) ==
            FileSystemEntityType.notFound) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Native socket not ready: $diagnostics');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        // Keep Dart's global wait() reaper active while Rust repeatedly starts
        // and waits for its own wpctl children. They must be grandchildren of
        // this VM, so its reaper cannot consume their exit status.
        dartChild = await Process.start('/bin/sleep', ['30']);
        for (var i = 0; i < 40; i++) {
          final socket = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
          );
          try {
            socket.write('{"op":"volume"}\n');
            final line = await socket
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first
                .timeout(const Duration(seconds: 60));
            final response = jsonDecode(line) as Map<String, dynamic>;
            expect(response['ok'], isTrue, reason: 'request $i: $line');
            expect(response['level'], 50, reason: line);
          } finally {
            socket.destroy();
          }
        }
        expect(diagnostics.toString(), isNot(contains('No child processes')));
      } finally {
        for (final process in [dartChild, native]) {
          if (process == null) continue;
          process.kill();
          await process.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () async {
              process.kill(ProcessSignal.sigkill);
              return process.exitCode;
            },
          );
        }
        await output?.cancel();
        await errors?.cancel();
        await directory.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set TEMPOD_TEST_NATIVE_EXECUTABLE to the native broker binary.'
        : false,
  );
}
