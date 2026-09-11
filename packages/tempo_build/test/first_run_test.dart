import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../../../platform/rootfs/tool/first_run.dart';

void main() {
  late Directory root;
  late List<(List<String>, String?)> commands;
  late FirstRunApply apply;
  void file(String relative, String contents) => File('${root.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
  String read(String relative) =>
      File('${root.path}/$relative').readAsStringSync();

  setUp(() {
    root = Directory.systemTemp.createTempSync('first-run');
    commands = [];
    apply = FirstRunApply(
      root: root.path,
      run: (argv, {stdin}) async {
        commands.add((argv, stdin));
        return 0;
      },
    );
    file('var/lib/tempo/account', '{"user":"tempo","uid":1000,"gid":1000}\n');
    file('etc/hostname', 'tempo\n');
    file('etc/hosts', '127.0.0.1\tlocalhost\n127.0.1.1\ttempo\n');
    file('usr/share/zoneinfo/Europe/Berlin', 'TZif2....');
    file(
      'usr/local/lib/tempo-system/account/etc/systemd/system/tempo.service.d/10-user.conf',
      '[Service]\nUser=@USER@\nGroup=@USER@\nEnvironment=XDG_RUNTIME_DIR=/run/user/@UID@\n',
    );
    file(
      'usr/local/lib/tempo-system/account/etc/sudoers.d/10-tempo',
      '@USER@ ALL=(ALL:ALL) NOPASSWD: ALL\n',
    );
    file('var/lib/systemd/linger/tempo', '');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('nothing waiting is nothing done', () async {
    await apply.apply();
    expect(commands, isEmpty);
    expect(apply.done.existsSync(), isFalse);
  });

  test(
    'a complete configuration renames the account, sets everything and finishes',
    () async {
      file(
        'first-run-config.json',
        jsonEncode({
          'username': 'alice',
          'password_hash': r'$6$salt$hash',
          'hostname': 'alices-player',
          'pretty_hostname': "Alice's Player",
          'timezone': 'Europe/Berlin',
          'ssh_keys': ['ssh-ed25519 AAAA alice@laptop'],
        }),
      );
      await apply.apply();
      final argv = commands.map((c) => c.$1.join(' ')).toList();
      expect(
        argv,
        containsAllInOrder([
          'hostname alices-player',
          'usermod -l alice -d /home/alice -m tempo',
          'groupmod -n alice tempo',
          'systemctl daemon-reload',
          'chpasswd -e',
          'chown -R 1000:1000 ${root.path}/home/alice/.ssh',
        ]),
      );
      expect(
        commands.firstWhere((c) => c.$1.first == 'chpasswd').$2,
        'alice:\$6\$salt\$hash\n',
      );
      expect(
        argv.join(' '),
        isNot(contains(r'$6$')),
        reason: 'the hash never rides argv',
      );
      expect(read('etc/hostname'), 'alices-player\n');
      expect(
        read('etc/hosts'),
        '127.0.0.1\tlocalhost\n127.0.1.1\talices-player\n',
      );
      expect(read('etc/machine-info'), 'PRETTY_HOSTNAME="Alice\'s Player"\n');
      expect(
        Link('${root.path}/etc/localtime').targetSync(),
        '/usr/share/zoneinfo/Europe/Berlin',
      );
      expect(read('etc/timezone'), 'Europe/Berlin\n');
      expect(
        read('etc/systemd/system/tempo.service.d/10-user.conf'),
        contains(
          'User=alice\nGroup=alice\nEnvironment=XDG_RUNTIME_DIR=/run/user/1000\n',
        ),
      );
      expect(
        read('etc/sudoers.d/10-tempo'),
        'alice ALL=(ALL:ALL) NOPASSWD: ALL\n',
      );
      expect(
        File('${root.path}/var/lib/systemd/linger/tempo').existsSync(),
        isFalse,
      );
      expect(
        File('${root.path}/var/lib/systemd/linger/alice').existsSync(),
        isTrue,
      );
      expect(
        read('var/lib/tempo/account'),
        '{"user":"alice","uid":1000,"gid":1000}\n',
      );
      expect(
        read('home/alice/.ssh/authorized_keys'),
        'ssh-ed25519 AAAA alice@laptop\n',
      );
      expect(jsonDecode(read('var/lib/tempo/first-run/applied.json')), {
        'username': 'alice',
        'hostname': 'alices-player',
        'pretty_hostname': "Alice's Player",
        'timezone': 'Europe/Berlin',
        'password': true,
        'ssh_keys': 1,
      });
      expect(apply.done.existsSync(), isTrue);
      expect(apply.flasherConfig.existsSync(), isFalse, reason: 'consumed');
      expect(apply.error.existsSync(), isFalse);
    },
  );

  test(
    'a partial configuration applies what it has and leaves first run open',
    () async {
      file(
        'var/lib/tempo/first-run/pending.json',
        jsonEncode({
          'timezone': 'Europe/Berlin',
          'ssh_keys': ['ssh-rsa BBBB me'],
        }),
      );
      await apply.apply();
      expect(commands.map((c) => c.$1.first), isNot(contains('usermod')));
      expect(read('home/tempo/.ssh/authorized_keys'), 'ssh-rsa BBBB me\n');
      expect(jsonDecode(read('var/lib/tempo/first-run/applied.json')), {
        'timezone': 'Europe/Berlin',
        'ssh_keys': 1,
      });
      expect(apply.done.existsSync(), isFalse);
      expect(apply.pending.existsSync(), isFalse);
    },
  );

  test(
    'the device word wins over the flasher and later applies add up',
    () async {
      file(
        'first-run-config.json',
        jsonEncode({'hostname': 'from-flasher', 'timezone': 'Europe/Berlin'}),
      );
      file(
        'var/lib/tempo/first-run/pending.json',
        jsonEncode({'hostname': 'from-device'}),
      );
      await apply.apply();
      expect(read('etc/hostname'), 'from-device\n');
      file(
        'var/lib/tempo/first-run/pending.json',
        jsonEncode({'username': 'bob', 'password_hash': r'$y$j9T$abc'}),
      );
      await apply.apply();
      expect(jsonDecode(read('var/lib/tempo/first-run/applied.json')), {
        'hostname': 'from-device',
        'timezone': 'Europe/Berlin',
        'username': 'bob',
        'password': true,
      });
      expect(apply.done.existsSync(), isTrue);
    },
  );

  test('a bad file changes nothing, is consumed, and says why', () async {
    for (final bad in [
      {'username': 'root'},
      {'username': 'Alice'},
      {'password_hash': 'plaintext'},
      {'hostname': 'not valid!'},
      {'timezone': '../../etc/passwd'},
      {'timezone': 'Mars/Olympus'},
      {
        'ssh_keys': ['not a key'],
      },
      {'colour': 'blue'},
    ]) {
      file('first-run-config.json', jsonEncode(bad));
      await expectLater(
        apply.apply(),
        throwsA(anything),
        reason: jsonEncode(bad),
      );
      expect(commands, isEmpty, reason: jsonEncode(bad));
      expect(read('etc/hostname'), 'tempo\n');
      expect(apply.flasherConfig.existsSync(), isFalse);
      expect(apply.error.existsSync(), isTrue);
      expect(apply.done.existsSync(), isFalse);
    }
  });
}
