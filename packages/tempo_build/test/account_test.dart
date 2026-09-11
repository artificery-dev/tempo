import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Repository repo;
  final templates = Directory(
    p.join(Directory.current.path, '..', '..', 'platform', 'rootfs', 'account'),
  );
  setUp(() {
    root = Directory.systemTemp.createTempSync('account-test');
    repo = Repository(root.path);
    for (final entry in templates.listSync(recursive: true)) {
      if (entry is! File) continue;
      final relative = p.relative(entry.path, from: templates.path);
      File(repo.path('platform/rootfs/account/$relative'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entry.readAsBytesSync());
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('every file that names the account is rendered from the templates', () {
    final files = renderAccountFiles(
      repo,
      const Account(
        user: 'alice',
        uid: '1000',
        gid: '1000',
        passwordlessSudo: true,
      ),
    );
    expect(files.keys.toSet(), {
      'etc/systemd/system/tempod.socket.d/10-group.conf',
      'etc/systemd/system/tempod.service.d/20-runtime.conf',
      'etc/systemd/system/tempo.service.d/10-user.conf',
      'etc/systemd/system/getty@tty1.service.d/autologin.conf',
      'etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf',
      'etc/sudoers.d/10-tempo',
    });
    for (final content in files.values) {
      expect(content, isNot(contains('@USER@')));
      expect(content, isNot(contains('@UID@')));
      expect(content, isNot(contains('@GID@')));
      expect(content, isNot(contains('tempo ')));
    }
    expect(
      files['etc/systemd/system/tempod.socket.d/10-group.conf'],
      '[Socket]\nSocketGroup=alice\n',
    );
    expect(
      files['etc/systemd/system/tempo.service.d/10-user.conf'],
      contains(
        'User=alice\nGroup=alice\nEnvironment=XDG_RUNTIME_DIR=/run/user/1000\n',
      ),
    );
    expect(
      files['etc/systemd/system/tempod.service.d/20-runtime.conf'],
      contains('TEMPOD_SETTINGS_FILE=/home/alice/.config/tempo/settings.json'),
    );
    expect(
      files['etc/sudoers.d/10-tempo'],
      contains('alice ALL=(ALL:ALL) NOPASSWD: ALL'),
    );
  });

  test('sudoers is only rendered for a passwordless sudoer', () {
    final files = renderAccountFiles(
      repo,
      const Account(
        user: 'alice',
        uid: '1000',
        gid: '1000',
        passwordlessSudo: false,
      ),
    );
    expect(files.containsKey('etc/sudoers.d/10-tempo'), isFalse);
  });

  test('account names follow the rule the device applies too', () {
    for (final ok in ['tempo', 'alice', 'a_b-c1', '_x']) {
      expect(validAccountName(ok), isTrue, reason: ok);
    }
    for (final bad in ['root', 'Alice', '1abc', 'a b', '', 'a' * 33, 'ab\n']) {
      expect(validAccountName(bad), isFalse, reason: bad);
    }
    expect(
      () => renderAccountFiles(
        repo,
        const Account(
          user: 'root',
          uid: '0',
          gid: '0',
          passwordlessSudo: false,
        ),
      ),
      throwsA(isA<BuildFailure>()),
    );
  });
}
