import 'dart:convert';
import 'dart:io';

/// What a first-run configuration may say, whether the flasher wrote it to
/// `/first-run-config.json` or the on-device setup left it as pending.
///
/// Every field is optional; what is present is applied, what is absent is
/// left for the setup on the device to ask. First run is done once the
/// account has a name and a password, the device a name, and the clock a
/// zone. A password only ever arrives hashed.
const firstRunFields = [
  'username',
  'password_hash',
  'hostname',
  'pretty_hostname',
  'timezone',
  'locale',
  'ssh_keys',
];
const firstRunRequired = ['username', 'password_hash', 'hostname', 'timezone'];

/// Runs a command as root; the stdin text is for a password hash, which
/// must never appear in argv. Returns the exit code.
typedef RootCommand = Future<int> Function(List<String> argv, {String? stdin});

Future<int> runRootCommand(List<String> argv, {String? stdin}) async {
  final process = await Process.start(argv.first, argv.sublist(1));
  if (stdin != null) process.stdin.write(stdin);
  await process.stdin.close();
  final errors = process.stderr.transform(utf8.decoder).join();
  await process.stdout.drain<void>();
  final code = await process.exitCode;
  if (code != 0) stderr.write(await errors);
  return code;
}

final class FirstRunApply {
  FirstRunApply({this.root = '/', RootCommand? run})
    : run = run ?? runRootCommand;
  final String root;
  final RootCommand run;

  String at(String relative) => root == '/' ? '/$relative' : '$root/$relative';
  File get flasherConfig => File(at('first-run-config.json'));
  File get pending => File(at('var/lib/tempo/first-run/pending.json'));
  File get applied => File(at('var/lib/tempo/first-run/applied.json'));
  File get error => File(at('var/lib/tempo/first-run/error'));
  File get done => File(at('var/lib/tempo/first-run/done'));
  File get account => File(at('var/lib/tempo/account'));
  Directory get templates =>
      Directory(at('usr/local/lib/tempo-system/account'));

  /// Applies whatever configuration is waiting. The inputs are consumed
  /// either way, so a bad file is reported once rather than every boot.
  Future<void> apply() async {
    final inputs = [flasherConfig, pending].where((f) => f.existsSync());
    if (inputs.isEmpty) return;
    Map<String, Object?> config = {};
    try {
      // The setup on the device runs after the flasher's file was applied,
      // so the two rarely coexist; when they do, the device's word wins.
      for (final input in inputs) {
        final read = jsonDecode(input.readAsStringSync());
        if (read is! Map) throw const FormatException('not an object');
        config = {...config, ...read.cast<String, Object?>()};
      }
      final values = validate(config);
      await _apply(values);
      _record(values);
      if (error.existsSync()) error.deleteSync();
    } on Object catch (failure) {
      error.parent.createSync(recursive: true);
      error.writeAsStringSync('$failure\n');
      rethrow;
    } finally {
      for (final input in inputs) {
        if (input.existsSync()) input.deleteSync();
      }
    }
  }

  static final _name = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');
  static final _host = RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,62}$');
  static final _hash = RegExp(r'^\$(y|gy|7|2[abxy]|6|5|1)\$');
  static final _key = RegExp(r'^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)\S+ \S+');
  static final _locale = RegExp(r'^[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]+)?$');

  /// Checks every field before anything is changed, so a bad file changes
  /// nothing at all.
  Map<String, Object?> validate(Map<String, Object?> config) {
    final unknown = config.keys.where((k) => !firstRunFields.contains(k));
    if (unknown.isNotEmpty) {
      throw FormatException('unknown fields: ${unknown.join(', ')}');
    }
    String? text(String key, RegExp pattern, String what) {
      final value = config[key];
      if (value == null) return null;
      if (value is! String || !pattern.hasMatch(value)) {
        throw FormatException('$key is not a valid $what');
      }
      return value;
    }

    final username = text('username', _name, 'account name');
    if (username == 'root') throw const FormatException('username is root');
    final hash = text('password_hash', _hash, 'crypt hash');
    final hostname = text('hostname', _host, 'host name');
    final pretty = config['pretty_hostname'];
    if (pretty != null && (pretty is! String || pretty.contains('\n'))) {
      throw const FormatException('pretty_hostname is not a line of text');
    }
    final zone = config['timezone'];
    if (zone != null) {
      if (zone is! String ||
          zone.isEmpty ||
          zone.startsWith('/') ||
          zone.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
        throw const FormatException('timezone is not a zone name');
      }
      final file = File(at('usr/share/zoneinfo/$zone'));
      if (!file.existsSync() ||
          String.fromCharCodes(file.openSync().readSync(4)) != 'TZif') {
        throw FormatException('timezone is unknown: $zone');
      }
    }
    final locale = text('locale', _locale, 'locale');
    final keys = config['ssh_keys'];
    if (keys != null &&
        (keys is! List || keys.any((k) => k is! String || !_key.hasMatch(k)))) {
      throw const FormatException('ssh_keys is not a list of public keys');
    }
    return {
      'username': username,
      'password_hash': hash,
      'hostname': hostname,
      'pretty_hostname': pretty,
      'timezone': zone,
      'locale': locale,
      'ssh_keys': (keys as List?)?.cast<String>(),
    };
  }

  Future<void> _apply(Map<String, Object?> values) async {
    final current = jsonDecode(account.readAsStringSync()) as Map;
    var user = current['user'] as String;
    final uid = '${current['uid']}', gid = '${current['gid']}';

    if (values['hostname'] case final String hostname) {
      File(at('etc/hostname')).writeAsStringSync('$hostname\n');
      final hosts = File(at('etc/hosts'));
      final lines = hosts.existsSync() ? hosts.readAsLinesSync() : <String>[];
      final kept = lines.where((l) => !l.startsWith('127.0.1.1')).toList();
      hosts.writeAsStringSync(
        '${[...kept, '127.0.1.1\t$hostname'].join('\n')}\n',
      );
      await _root(['hostname', hostname]);
      if (values['pretty_hostname'] case final String pretty) {
        final escaped = pretty.replaceAll('"', r'\"');
        File(
          at('etc/machine-info'),
        ).writeAsStringSync('PRETTY_HOSTNAME="$escaped"\n');
      }
    }
    if (values['timezone'] case final String zone) {
      final link = Link(at('etc/localtime'));
      if (link.existsSync()) link.deleteSync();
      link.createSync('/usr/share/zoneinfo/$zone');
      File(at('etc/timezone')).writeAsStringSync('$zone\n');
    }
    if (values['locale'] case final String locale) {
      await _root(['update-locale', 'LANG=$locale']);
    }
    if (values['username'] case final String name when name != user) {
      await _root(['usermod', '-l', name, '-d', '/home/$name', '-m', user]);
      await _root(['groupmod', '-n', name, user]);
      final linger = File(at('var/lib/systemd/linger/$user'));
      if (linger.existsSync()) linger.deleteSync();
      File(at('var/lib/systemd/linger/$name'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      user = name;
      account.writeAsStringSync('{"user":"$user","uid":$uid,"gid":$gid}\n');
      _render(user: user, uid: uid, gid: gid);
      await _root(['systemctl', 'daemon-reload']);
    }
    if (values['password_hash'] case final String hash) {
      await _root(['chpasswd', '-e'], stdin: '$user:$hash\n');
    }
    if (values['ssh_keys'] case final List<String> keys when keys.isNotEmpty) {
      final directory = Directory(at('home/$user/.ssh'))
        ..createSync(recursive: true);
      final file = File('${directory.path}/authorized_keys');
      final existing = file.existsSync() ? file.readAsLinesSync() : <String>[];
      final all = {...existing.where((l) => l.trim().isNotEmpty), ...keys};
      file.writeAsStringSync('${all.join('\n')}\n');
      await _root(['chmod', '700', directory.path]);
      await _root(['chmod', '600', file.path]);
      await _root(['chown', '-R', '$uid:$gid', directory.path]);
    }
  }

  /// Renders the account templates the image carries, the same ones the
  /// build rendered, for the account's new name.
  void _render({
    required String user,
    required String uid,
    required String gid,
  }) {
    for (final entry in templates.listSync(recursive: true)) {
      if (entry is! File) continue;
      final relative = entry.path.substring(templates.path.length + 1);
      final rendered = entry
          .readAsStringSync()
          .replaceAll('@USER@', user)
          .replaceAll('@UID@', uid)
          .replaceAll('@GID@', gid);
      File(at(relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(rendered);
    }
  }

  Future<void> _root(List<String> argv, {String? stdin}) async {
    final code = await run(argv, stdin: stdin);
    if (code != 0) throw StateError('${argv.first} failed with $code');
  }

  void _record(Map<String, Object?> values) {
    applied.parent.createSync(recursive: true);
    final previous = applied.existsSync()
        ? (jsonDecode(applied.readAsStringSync()) as Map)
              .cast<String, Object?>()
        : <String, Object?>{};
    // Nothing secret is recorded: the app reads this to know what to skip.
    final record = {
      ...previous,
      for (final key in [
        'username',
        'hostname',
        'pretty_hostname',
        'timezone',
        'locale',
      ])
        if (values[key] != null) key: values[key],
      if (values['password_hash'] != null) 'password': true,
      if (values['ssh_keys'] case final List<String> keys when keys.isNotEmpty)
        'ssh_keys': keys.length,
    };
    applied.writeAsStringSync('${jsonEncode(record)}\n');
    final complete = firstRunRequired.every(
      (key) => key == 'password_hash'
          ? record['password'] == true
          : record[key] != null,
    );
    if (complete) done.writeAsStringSync('');
  }
}
