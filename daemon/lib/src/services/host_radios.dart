import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';

typedef RadioCommand =
    Future<String> Function(
      String executable,
      List<String> arguments, {
      String? input,
    });
typedef BluetoothScan =
    Future<void> Function(List<String> filters, Duration duration);

/// Child clients must not inherit the daemon's systemd notification endpoint.
/// Supplying a full environment is necessary: Process.start otherwise merges
/// back omitted parent keys, and Platform.environment may cache native unsetenv.
Map<String, String> radioChildEnvironment({Map<String, String>? parent}) => {
  for (final entry in (parent ?? Platform.environment).entries)
    if (!const {
      'NOTIFY_SOCKET',
      'WATCHDOG_PID',
      'WATCHDOG_USEC',
      'LISTEN_PID',
      'LISTEN_FDS',
      'LISTEN_FDNAMES',
    }.contains(entry.key))
      entry.key: entry.value,
  'LC_ALL': 'C',
  'TERM': 'dumb',
};

/// Commands use argument vectors, a fixed locale, and bounded process lifetimes.
/// Credentials go through stdin and are never included in reported errors.
Future<String> runRadioCommand(
  String executable,
  List<String> arguments, {
  String? input,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: radioChildEnvironment(),
    includeParentEnvironment: false,
  );
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final int code;
  try {
    code = await process.exitCode.timeout(const Duration(seconds: 40));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([stdout, stderr]);
    throw RadioFailure('$executable timed out. Try again.');
  }
  final output = (await stdout).replaceAll(
    RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'),
    '',
  );
  await stderr;
  if (code != 0 ||
      RegExp(
        r'(^|\n|> )(FAIL\S*|Failed\b|Error\b|No default controller|Not available)',
        caseSensitive: false,
      ).hasMatch(output)) {
    throw RadioFailure(
      '$executable could not complete the request. Check the service, radio and permissions.',
    );
  }
  return output.trim();
}

/// Run an interactive BlueZ discovery client long enough for its per-client
/// filters to remain active. A one-shot `bluetoothctl scan` process drops the
/// filter as soon as that D-Bus client exits.
Future<void> runBluetoothScan(List<String> filters, Duration duration) async {
  final process = await Process.start(
    'bluetoothctl',
    const [],
    environment: radioChildEnvironment(),
    includeParentEnvironment: false,
  );
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  try {
    process.stdin.writeln('menu scan');
    for (final filter in filters) {
      process.stdin.writeln(filter);
    }
    process.stdin.writeln('back');
    process.stdin.writeln('scan on');
    await process.stdin.flush();
    await Future<void>.delayed(duration);
    process.stdin.writeln('scan off');
    process.stdin.writeln('quit');
    await process.stdin.close();
  } on Object {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([stdout, stderr]);
    throw const RadioFailure(
      'bluetoothctl could not configure filtered discovery.',
    );
  }
  final int code;
  try {
    code = await process.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([stdout, stderr]);
    throw const RadioFailure('bluetoothctl discovery timed out. Try again.');
  }
  final output = (await stdout).replaceAll(
    RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'),
    '',
  );
  await stderr;
  if (code != 0 ||
      RegExp(
        r'(^|\n|> )(FAIL\S*|Failed\b|Error\b|No default controller|Not available)',
        caseSensitive: false,
      ).hasMatch(output)) {
    throw const RadioFailure('bluetoothctl could not scan for audio devices.');
  }
}

class HostRadios extends RadioBackend {
  HostRadios({
    RadioCommand? command,
    BluetoothScan? bluetoothScan,
    this._interface,
  }) : command = command ?? runRadioCommand,
       bluetoothScan = bluetoothScan ?? runBluetoothScan;
  final RadioCommand command;
  final BluetoothScan bluetoothScan;
  String? _interface;

  Future<String> _iface() async {
    if (_interface case final String name) return name;
    final configured = Platform.environment['TEMPO_WIFI_INTERFACE'];
    if (configured != null &&
        RegExp(r'^[a-zA-Z0-9_.:-]+$').hasMatch(configured)) {
      return _interface = configured;
    }
    final root = Directory('/sys/class/net');
    if (await root.exists()) {
      await for (final entry in root.list()) {
        if (await Directory('${entry.path}/wireless').exists()) {
          return _interface = entry.path.split('/').last;
        }
      }
    }
    throw const RadioFailure('No Wi-Fi interface found on the host.');
  }

  Future<String> _wpa(List<String> args, {String? input}) async =>
      command('wpa_cli', ['-i', await _iface(), ...args], input: input);
  // BlueZ's --timeout keeps even completed reads alive until the deadline.
  // Let normal commands exit on completion; runRadioCommand still bounds them.
  Future<String> _bt(List<String> args) => command('bluetoothctl', args);

  static const _a2dpSinkUuid = '0000110b-0000-1000-8000-00805f9b34fb';

  Future<String> _connectA2dp(String address) => command('busctl', [
    'call',
    'org.bluez',
    '/org/bluez/hci0/dev_${address.replaceAll(':', '_').toUpperCase()}',
    'org.bluez.Device1',
    'ConnectProfile',
    's',
    _a2dpSinkUuid,
  ]);

  static Map<String, String> fields(String output) => {
    for (final line in output.split('\n'))
      if (line.contains('='))
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
  };
  // wpa_supplicant renders non-ASCII SSID bytes as \xNN escapes.
  static String decodeSsid(String value) {
    final bytes = <int>[];
    for (var i = 0; i < value.length; i++) {
      if (value[i] == '\\' && i + 1 < value.length) {
        final next = value[i + 1];
        if (next == 'x' && i + 3 < value.length) {
          final byte = int.tryParse(value.substring(i + 2, i + 4), radix: 16);
          if (byte != null) {
            bytes.add(byte);
            i += 3;
            continue;
          }
        }
        final escaped = {
          'n': 10,
          'r': 13,
          't': 9,
          'e': 27,
          '\\': 92,
          '"': 34,
        }[next];
        if (escaped != null) {
          bytes.add(escaped);
          i++;
          continue;
        }
      }
      // Ordinary CLI output is ASCII; preserve literal UTF-16 pairs too.
      if (value.codeUnitAt(i) >= 0xd800 &&
          value.codeUnitAt(i) <= 0xdbff &&
          i + 1 < value.length) {
        bytes.addAll(utf8.encode(value.substring(i, i + 2)));
        i++;
      } else {
        bytes.addAll(utf8.encode(value[i]));
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static int signalBars(int dbm) => dbm >= -55
      ? 3
      : dbm >= -70
      ? 2
      : 1;
  static List<WifiNetwork> parseNetworks(
    String scans,
    String saved,
    String? current,
  ) {
    final known = <String, String>{};
    for (final line in saved.split('\n')) {
      final cols = line.split('\t');
      if (cols.length >= 4 && int.tryParse(cols[0]) != null) {
        known[decodeSsid(cols[1])] = cols[0];
      }
    }
    final found = <String, WifiNetwork>{};
    for (final line in scans.split('\n')) {
      final cols = line.split('\t');
      if (cols.length < 5 || int.tryParse(cols[2]) == null || cols[4].isEmpty) {
        continue;
      }
      final name = decodeSsid(cols.sublist(4).join('\t'));
      final n = WifiNetwork(
        name,
        id: known[name],
        bars: signalBars(int.parse(cols[2])),
        security: cols[3],
        connected: current == name,
      );
      if (!found.containsKey(name) || found[name]!.bars < n.bars) {
        found[name] = n;
      }
    }
    for (final entry in known.entries) {
      found.putIfAbsent(
        entry.key,
        () => WifiNetwork(
          entry.key,
          id: entry.value,
          connected: current == entry.key,
        ),
      );
    }
    return found.values.toList()..sort(
      (a, b) => a.connected != b.connected
          ? (a.connected ? -1 : 1)
          : b.bars.compareTo(a.bars),
    );
  }

  @override
  Future<void> refresh({bool scan = false}) async {
    // A missing service must not hide the other radio.
    await Future.wait([_refreshWifi(scan), _refreshBluetooth(scan)]);
  }

  Future<void> _refreshWifi(bool scan) async {
    try {
      final status = fields(await _wpa(['status']));
      if (!status.containsKey('wpa_state')) {
        throw const RadioFailure(
          'wpa_supplicant is unavailable for this interface.',
        );
      }
      if (status['ssid'] case final ssid?) status['ssid'] = decodeSsid(ssid);
      final connected = status['wpa_state'] == 'COMPLETED';
      final enabled = status['wpa_state'] != 'INTERFACE_DISABLED';
      if (scan && enabled) {
        await _wpa(['scan']);
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      final list = parseNetworks(
        await _wpa(['scan_results']),
        await _wpa(['list_networks']),
        connected ? status['ssid'] : null,
      );
      final current = list.where((n) => n.connected);
      wifi = WifiReading(
        status: connected
            ? WifiStatus.connected
            : enabled
            ? WifiStatus.disconnected
            : WifiStatus.off,
        network: connected ? status['ssid'] : null,
        bars: current.isEmpty ? 0 : current.first.bars,
      );
      networks = list;
      wifiError = null;
    } on Object catch (e) {
      wifi = WifiReading.off;
      networks = [];
      wifiError = e is RadioFailure
          ? e.message
          : 'Wi-Fi unavailable. Check wpa_supplicant and host permissions.';
    }
  }

  Future<void> _refreshBluetooth(bool scan) async {
    try {
      final controller = await _bt(['show']);
      if (!controller.contains('Controller ')) {
        throw const RadioFailure('No Bluetooth controller found on the host.');
      }
      final powered = controller.contains('Powered: yes');
      if (scan && powered) {
        await bluetoothScan([
          'transport bredr',
          'uuids $_a2dpSinkUuid',
        ], const Duration(seconds: 5));
      }
      final result = <BluetoothDevice>[];
      for (final line in (await _bt(['devices'])).split('\n')) {
        final match = RegExp(
          r'^Device ([0-9A-Fa-f:]{17}) (.+)$',
        ).firstMatch(line);
        if (match == null) continue;
        final info = await _bt(['info', match[1]!]);
        if (!info.toLowerCase().contains(_a2dpSinkUuid)) continue;
        result.add(
          BluetoothDevice(
            match[1]!,
            match[2]!,
            paired: info.contains('Paired: yes'),
            connected: powered && info.contains('Connected: yes'),
          ),
        );
      }
      devices = result;
      final active = result.where((d) => d.connected);
      bluetooth = BluetoothReading(
        status: !powered
            ? BluetoothStatus.off
            : active.isEmpty
            ? BluetoothStatus.on
            : BluetoothStatus.connected,
        device: active.isEmpty ? null : active.first.name,
      );
      bluetoothError = null;
    } on Object catch (e) {
      bluetooth = BluetoothReading.off;
      devices = [];
      bluetoothError = e is RadioFailure
          ? e.message
          : 'Bluetooth unavailable. Check BlueZ and host permissions.';
    }
  }

  Future<void> _managed() async {
    final links = await command('networkctl', [
      '--no-pager',
      '--no-legend',
      'list',
      await _iface(),
    ]);
    if (links.isEmpty ||
        links.contains('unmanaged') ||
        links.contains('not-found')) {
      throw const RadioFailure(
        'This Wi-Fi interface needs a systemd-networkd .network configuration.',
      );
    }
  }

  @override
  Future<void> enableWifi(bool enabled) async {
    await _managed();
    await command('networkctl', [enabled ? 'up' : 'down', await _iface()]);
    if (enabled) await _wpa(['reconnect']);
  }

  static String _hex(String value) =>
      utf8.encode(value).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  @override
  Future<void> join(WifiNetwork n, String password) async {
    await _managed();
    if (!n.supported) {
      throw const RadioFailure(
        'This network requires an authentication method not supported here yet.',
      );
    }
    if (n.secured &&
        n.id == null &&
        (utf8.encode(password).length < 8 ||
            utf8.encode(password).length > 63 ||
            password.contains(RegExp(r'[\r\n\x00]')))) {
      throw const RadioFailure('Use a Wi-Fi password of 8–63 bytes.');
    }
    var id = n.id;
    final created = id == null;
    if (id == null) {
      id = (await _wpa(['add_network'])).split('\n').last.trim();
      if (int.tryParse(id) == null) {
        throw const RadioFailure('Could not create the Wi-Fi profile.');
      }
    }
    try {
      if (created) {
        await _wpa(['set_network', id, 'ssid', _hex(n.ssid)]);
        if (n.secured) {
          final escaped = password
              .replaceAll('\\', '\\\\')
              .replaceAll('"', '\\"');
          final reply = await _wpa(
            [],
            input: 'set_network $id psk "$escaped"\nquit\n',
          );
          if (!RegExp(r'(^|\n)OK\s*($|\n)').hasMatch(reply)) {
            throw const RadioFailure('Could not configure Wi-Fi credentials.');
          }
        } else {
          await _wpa(['set_network', id, 'key_mgmt', 'NONE']);
        }
      }
      await command('networkctl', ['up', await _iface()]);
      await _wpa(['select_network', id]);
      // Association is asynchronous. Do not report a successful connection
      // merely because SELECT_NETWORK was accepted.
      var connected = false;
      for (var attempt = 0; attempt < 15; attempt++) {
        final status = fields(await _wpa(['status']));
        if (status['wpa_state'] == 'COMPLETED' && status['id'] == id) {
          connected = true;
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!connected) {
        throw const RadioFailure(
          'Could not join the network. Check the password and signal, then retry.',
        );
      }
    } on Object {
      if (created) await _wpa(['remove_network', id]);
      rethrow;
    }
    await command('networkctl', ['renew', await _iface()]);
    await _save();
  }

  Future<void> _save() async {
    try {
      await _wpa(['save_config']);
    } on Object {
      throw const RadioFailure(
        'The Wi-Fi change is active for this session, but could not be saved. Check wpa_supplicant update_config and file permissions.',
      );
    }
  }

  @override
  Future<void> disconnectWifi() async {
    await _wpa(['disconnect']);
  }

  @override
  Future<void> forgetWifi(WifiNetwork n) async {
    if (n.id == null) return;
    await _wpa(['remove_network', n.id!]);
    await _save();
  }

  @override
  Future<void> enableBluetooth(bool enabled) async {
    await _bt(['power', enabled ? 'on' : 'off']);
  }

  @override
  Future<void> connectBluetooth(BluetoothDevice d) async {
    if (!d.paired) await _bt(['--agent', 'NoInputNoOutput', 'pair', d.address]);
    await _connectA2dp(d.address);
  }

  @override
  Future<void> disconnectBluetooth(BluetoothDevice d) async {
    await _bt(['disconnect', d.address]);
  }

  @override
  Future<void> forgetBluetooth(BluetoothDevice d) async {
    await _bt(['remove', d.address]);
  }
}
