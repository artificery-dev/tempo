import 'dart:io';
import 'package:toolbox_core/live_device.dart';
import 'package:test/test.dart';

void main() {
  test('keepalive defaults also apply to custom SSH option lists', () {
    final transport = SshDeviceTransport(
      host: 'test',
      user: 'tempo',
      options: ['-p', '2222'],
    );
    expect(
      transport.options,
      containsAll([
        '-p',
        '2222',
        'ServerAliveInterval=5',
        'ServerAliveCountMax=3',
      ]),
    );
  });
  test(
    'rollback connection preserves endpoint and options after cancellation',
    () async {
      final forward = SshDeviceTransport(
        host: 'device',
        user: 'tempo',
        options: ['-p', '2222'],
      );
      await forward.cancel();
      final recovery = forward.newConnection();
      expect(forward.isCancelled, true);
      expect(recovery.isCancelled, false);
      expect(recovery.target, forward.target);
      expect(recovery.options, containsAllInOrder(['-p', '2222']));
      await recovery.cancel();
    },
  );
  group(
    'local SSH process lifecycle',
    () {
      late Directory temp;
      late File executable;
      setUp(() async {
        temp = Directory.systemTemp.createTempSync('fake-ssh');
        executable = File('${temp.path}/ssh')
          ..writeAsStringSync('#!/bin/sh\ntrap "" TERM\nexec sleep 60\n');
        expect(
          (await Process.run('chmod', ['755', executable.path])).exitCode,
          0,
        );
      });
      tearDown(() => temp.deleteSync(recursive: true));
      SshDeviceTransport transport() => SshDeviceTransport(
        host: 'never-contacted',
        user: 'tempo',
        sshExecutable: executable.path,
        transferIdleTimeout: const Duration(milliseconds: 100),
        killGracePeriod: const Duration(milliseconds: 30),
      );
      test(
        'stalled transfer fails by inactivity without a fixed file-size deadline',
        () async {
          final source = File('${temp.path}/upload')
            ..writeAsBytesSync(List.filled(4 * 1024 * 1024, 1));
          final ssh = transport();
          addTearDown(ssh.cancel);
          // What matters is why the upload fails, not how quickly: the wall
          // clock here measures forking a shell and killing it, which a busy
          // machine is slow at even when the code is right.
          await expectLater(
            ssh.upload(source, '/unused').timeout(const Duration(seconds: 60)),
            throwsA(
              isA<DeviceOperationFailure>().having(
                (failure) => failure.toString(),
                'message',
                contains('stalled'),
              ),
            ),
          );
        },
      );
      test('cancellation escalates and prevents subsequent commands', () async {
        final ssh = transport();
        final running = ssh.command(['unused']);
        final expected = expectLater(
          running,
          throwsA(isA<DeviceOperationFailure>()),
        );
        // The child ignores SIGTERM and has to be killed; both waiting for it
        // to start and waiting for it to die are the machine's business, not
        // this test's.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await ssh.cancel().timeout(const Duration(seconds: 60));
        await expected;
        await expectLater(
          ssh.command(['unused']),
          throwsA(isA<DeviceOperationFailure>()),
        );
      });
    },
    skip: Platform.isWindows ? 'POSIX fake process fixture' : false,
  );
}
