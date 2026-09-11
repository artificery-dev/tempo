/// First-run choices made in the Toolbox before flashing. The flasher
/// writes them into the fresh root filesystem through Tempo Recovery, and
/// the player asks for whatever was left blank on its first start.
///
/// Values are kept as typed; [toJson] gives the document the USB engine
/// takes, where the password still travels as typed. The engine hashes it
/// before anything reaches the player.
class DeviceSetup {
  const DeviceSetup({
    this.username = '',
    this.password = '',
    this.hostname = '',
    this.timezone = '',
    this.locale = '',
    this.sshKeys = '',
  });

  /// The engine's field names, as the toolbox CLI takes them in a file.
  factory DeviceSetup.fromJson(Map<String, Object?> json) {
    final unknown = json.keys.where((k) => !labels.containsKey(k));
    if (unknown.isNotEmpty) {
      throw FormatException(
        'Unknown device setup fields: ${unknown.join(', ')}',
      );
    }
    String text(String key) => switch (json[key]) {
      null => '',
      final String value => value,
      _ => throw FormatException('Device setup $key must be text'),
    };
    return DeviceSetup(
      username: text('username'),
      password: text('password'),
      hostname: text('hostname'),
      timezone: text('timezone'),
      locale: text('locale'),
      sshKeys: switch (json['ssh_keys']) {
        null => '',
        final String keys => keys,
        final List keys when keys.every((k) => k is String) => keys.join('\n'),
        _ => throw const FormatException('Device setup ssh_keys must be keys'),
      },
    );
  }

  final String username, password, hostname, timezone, locale, sshKeys;

  /// What each field is called to a person, by its wire name.
  static const labels = {
    'username': 'Account name',
    'password': 'Password',
    'hostname': 'Device name',
    'timezone': 'Time zone',
    'locale': 'Language',
    'ssh_keys': 'SSH keys',
  };

  DeviceSetup copyWith({
    String? username,
    String? password,
    String? hostname,
    String? timezone,
    String? locale,
    String? sshKeys,
  }) => DeviceSetup(
    username: username ?? this.username,
    password: password ?? this.password,
    hostname: hostname ?? this.hostname,
    timezone: timezone ?? this.timezone,
    locale: locale ?? this.locale,
    sshKeys: sshKeys ?? this.sshKeys,
  );

  List<String> get keys => [
    for (final key in sshKeys.split('\n'))
      if (key.trim().isNotEmpty) key.trim(),
  ];

  /// Only what was filled in; nothing here is asked for again.
  Map<String, Object?> toJson() => {
    if (username.trim().isNotEmpty) 'username': username.trim(),
    if (password.isNotEmpty) 'password': password,
    if (hostname.trim().isNotEmpty) 'hostname': hostname.trim(),
    if (timezone.trim().isNotEmpty) 'timezone': timezone.trim(),
    if (locale.trim().isNotEmpty) 'locale': locale.trim(),
    if (keys.isNotEmpty) 'ssh_keys': keys,
  };

  bool get isEmpty => toJson().isEmpty;

  /// The filled-in fields, as a person would list them.
  List<String> get configured => [
    for (final key in toJson().keys) labels[key]!,
  ];

  static final _name = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');
  static final _host = RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,62}$');
  static final _zone = RegExp(r'^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$');
  static final _locale = RegExp(r'^[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]+)?$');
  static final _key = RegExp(r'^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)\S+ \S+');

  /// What the player would refuse, by field, in a person's terms. Empty
  /// when everything filled in is acceptable; blanks are never a problem.
  Map<String, String> validate() {
    final document = toJson();
    final problems = <String, String>{};
    if (document['username'] case final String name) {
      if (name == 'root') {
        problems['username'] = 'The account cannot be root.';
      } else if (!_name.hasMatch(name)) {
        problems['username'] =
            'Lowercase letters, digits, - and _; up to 32, starting with a letter or _.';
      }
    }
    if (document['hostname'] case final String host
        when !_host.hasMatch(host)) {
      problems['hostname'] =
          'Letters, digits and -; up to 63, starting with a letter or digit.';
    }
    if (document['timezone'] case final String zone
        when !_zone.hasMatch(zone) ||
            zone.split('/').any((p) => p == '.' || p == '..')) {
      problems['timezone'] = 'A zone name such as Europe/Berlin or UTC.';
    }
    if (document['locale'] case final String locale
        when !_locale.hasMatch(locale)) {
      problems['locale'] = 'A locale such as en_US.UTF-8.';
    }
    if (keys.any((key) => !_key.hasMatch(key))) {
      problems['ssh_keys'] =
          'Public keys as ssh-keygen prints them, one per line.';
    }
    return problems;
  }
}
