import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tempod/src/services/host_radios.dart';

void main() {
  test(
    'radio children omit service ownership and preserve runtime environment',
    () async {
      final env = radioChildEnvironment(
        parent: {
          'NOTIFY_SOCKET': '/private/notify',
          'WATCHDOG_PID': '123',
          'WATCHDOG_USEC': '1000',
          'LISTEN_PID': '123',
          'LISTEN_FDS': '1',
          'LISTEN_FDNAMES': 'control',
          'PATH': '/usr/bin:/bin',
          'XDG_RUNTIME_DIR': '/run/user/1000',
          'LC_ALL': 'other',
        },
      );
      expect(env, {
        'PATH': '/usr/bin:/bin',
        'XDG_RUNTIME_DIR': '/run/user/1000',
        'LC_ALL': 'C',
        'TERM': 'dumb',
      });
      final result = await Process.run(
        '/usr/bin/env',
        [],
        environment: env,
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0);
      final actual = const LineSplitter()
          .convert(result.stdout as String)
          .toSet();
      expect(actual, env.entries.map((e) => '${e.key}=${e.value}').toSet());
    },
  );
}
