import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toolbox_core/live_device.dart';
import 'context.dart';
import 'process.dart';

Future<int> deviceLink(
  BuildConfig config,
  CommandRunner runner,
  SshDeviceTransport device,
  List<String> args,
) async {
  if (!Platform.isLinux)
    throw BuildFailure(
      'USB gadget link provisioning currently requires Linux; use host network settings on macOS/Windows',
    );
  var action = 'up', share = false;
  for (final arg in args) {
    if (['up', 'down', 'reset'].contains(arg)) {
      action = arg;
    } else if (arg == '--share') {
      share = true;
    } else {
      throw BuildFailure('Expected link up|down|reset [--share]', 2);
    }
  }
  final address = config.string('networking.usb_gadget.address').split('/'),
      octets = address.first.split('.').map(int.parse).toList(),
      prefix = int.parse(address[1]);
  if (octets.length != 4 ||
      octets.any((n) => n < 0 || n > 255) ||
      prefix < 1 ||
      prefix > 30)
    throw BuildFailure(
      'USB link requires an IPv4 subnet with at least two hosts',
    );
  final ip = octets.fold(0, (value, part) => (value << 8) | part),
      mask = (0xffffffff << (32 - prefix)) & 0xffffffff;
  String ipv4(int value) =>
      [24, 16, 8, 0].map((shift) => (value >> shift) & 255).join('.');
  final hostAddress = '${ipv4(ip + 1)}/$prefix',
      subnet = '${ipv4(ip & mask)}/$prefix';
  if (((ip + 1) & mask) != (ip & mask) || ((ip + 1) | mask) == 0xffffffff)
    throw BuildFailure(
      'Configured gadget address leaves no adjacent host address',
    );
  Future<ProcessResult> capture(String command, List<String> args) =>
      runner.capture(command, args, check: false);
  Future<bool> exists(String command) async =>
      (await capture('which', [command])).exitCode == 0;
  Future<int> sudo(String command, List<String> args, {bool check = true}) =>
      runner.run('sudo', [command, ...args], check: check);
  String? findInterface() {
    final matches = <String>[];
    for (final entry in Directory('/sys/class/net').listSync()) {
      try {
        final driver = p.basename(
          Link(p.join(entry.path, 'device/driver')).resolveSymbolicLinksSync(),
        );
        if (['cdc_ether', 'cdc_ncm', 'rndis_host'].contains(driver))
          matches.add(p.basename(entry.path));
      } on FileSystemException {
        /* not a USB gadget */
      }
    }
    matches.sort();
    if (matches.length > 1)
      stderr.writeln(
        'Multiple gadget interfaces: ${matches.join(', ')}; TEMPO_DEVICE_IFACE selects one',
      );
    return matches.firstOrNull;
  }

  var iface = Platform.environment['TEMPO_DEVICE_IFACE'] ?? findInterface();
  if (iface == null)
    throw BuildFailure(
      'No USB gadget network interface; connect the Y2 and wait for boot',
    );
  Future<bool> nmManages() async {
    if (!await exists('nmcli') ||
        (await capture('systemctl', [
              '-q',
              'is-active',
              'NetworkManager',
            ])).exitCode !=
            0)
      return false;
    final state = await capture('nmcli', [
      '-g',
      'GENERAL.STATE',
      'device',
      'show',
      iface!,
    ]);
    return state.exitCode == 0 &&
        !state.stdout.toString().contains('unmanaged');
  }

  Future<String> hostAddressNow() async {
    final result = await capture('ip', [
      '-4',
      '-o',
      'addr',
      'show',
      'dev',
      iface!,
    ]);
    final match = RegExp(
      r'\binet\s+(\S+)',
    ).firstMatch(result.stdout.toString());
    return match?[1] ?? '';
  }

  Future<void> reset() async {
    final physical = Directory(
      p.dirname(
        Link('/sys/class/net/$iface/device').resolveSymbolicLinksSync(),
      ),
    );
    if (!File(p.join(physical.path, 'idVendor')).existsSync())
      throw BuildFailure('Cannot resolve USB device behind $iface');
    final id = p.basename(physical.path);
    await runner.run('sudo', [
      'tee',
      '/sys/bus/usb/drivers/usb/unbind',
    ], input: Stream.value(utf8.encode('$id\n')));
    await Future<void>.delayed(const Duration(seconds: 2));
    await runner.run('sudo', [
      'tee',
      '/sys/bus/usb/drivers/usb/bind',
    ], input: Stream.value(utf8.encode('$id\n')));
    iface = null;
    for (var attempt = 0; attempt < 20; attempt++) {
      iface = Platform.environment['TEMPO_DEVICE_IFACE'] ?? findInterface();
      if (iface != null && Directory('/sys/class/net/$iface').existsSync())
        break;
      iface = null;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (iface == null)
      throw BuildFailure('USB gadget interface did not return after reset');
  }

  List<List<String>> rules() => [
    [
      '-t',
      'nat',
      'POSTROUTING',
      '-s',
      subnet,
      '!',
      '-o',
      iface!,
      '-j',
      'MASQUERADE',
    ],
    ['FORWARD', '-s', subnet, '-j', 'ACCEPT'],
    ['FORWARD', '-d', subnet, '-j', 'ACCEPT'],
  ];
  List<String> ruleCommand(List<String> rule, String operation) =>
      rule.first == '-t'
      ? [...rule.take(2), operation, ...rule.skip(2)]
      : [operation, ...rule];
  Future<void> route(bool add) async {
    if ((await capture('ping', ['-c1', '-W1', device.host])).exitCode != 0)
      return;
    try {
      if (add) {
        final gateway = (await hostAddressNow()).split('/').first;
        if (gateway.isEmpty) throw BuildFailure('Host has no gadget address');
        await device.command([
          'ip',
          'route',
          'replace',
          'default',
          'via',
          gateway,
          'dev',
          config.string('networking.usb_gadget.interface'),
        ], root: true);
        stdout.writeln(
          await device.command([
            'timeout',
            '10',
            'getent',
            'hosts',
            'deb.debian.org',
          ]),
        );
      } else {
        await device.command([
          'ip',
          'route',
          'del',
          'default',
          'dev',
          config.string('networking.usb_gadget.interface'),
        ], root: true);
      }
    } on Object catch (error) {
      stderr.writeln('Device default route: $error');
    }
  }

  if (action == 'down') {
    await route(false);
    if (await exists('iptables'))
      for (final rule in rules())
        await sudo('iptables', ruleCommand(rule, '-D'), check: false);
    if (await nmManages()) {
      await runner.run('nmcli', [
        '-w',
        '5',
        'con',
        'down',
        'tempo-link',
      ], check: false);
    } else {
      if (await exists('dhcpcd'))
        await sudo('dhcpcd', ['-k', iface!], check: false);
      if (await exists('dhclient'))
        await sudo('dhclient', ['-r', iface!], check: false);
      await sudo('ip', ['addr', 'flush', 'dev', iface!], check: false);
      await sudo('ip', ['link', 'set', iface!, 'down'], check: false);
    }
    return 0;
  }
  Future<void> configure() async {
    if (await nmManages()) {
      final connections = (await capture('nmcli', [
        '-g',
        'NAME',
        'con',
        'show',
      ])).stdout.toString().split('\n');
      if (!connections.contains('tempo-link'))
        await runner.run('nmcli', [
          'con',
          'add',
          'type',
          'ethernet',
          'ifname',
          iface!,
          'con-name',
          'tempo-link',
          'ipv4.method',
          'auto',
          'ipv4.never-default',
          'yes',
          'ipv4.dhcp-timeout',
          '15',
          'ipv6.method',
          'disabled',
          'connection.autoconnect',
          'yes',
        ]);
      await runner.run('nmcli', [
        'con',
        'modify',
        'tempo-link',
        'connection.interface-name',
        iface!,
        'ipv4.method',
        'auto',
        'ipv4.addresses',
        '',
        'ipv4.gateway',
        '',
        'ipv4.never-default',
        'yes',
      ]);
      if (await runner.run('nmcli', [
            '-w',
            '20',
            'con',
            'up',
            'tempo-link',
          ], check: false) !=
          0) {
        await runner.run('nmcli', [
          'con',
          'modify',
          'tempo-link',
          'ipv4.method',
          'manual',
          'ipv4.addresses',
          hostAddress,
        ]);
        await runner.run('nmcli', ['-w', '10', 'con', 'up', 'tempo-link']);
      }
    } else {
      await sudo('ip', ['link', 'set', iface!, 'up']);
      var lease = false;
      if (await exists('dhcpcd')) {
        lease =
            await sudo('dhcpcd', [
              '-1',
              '-t',
              '15',
              '--nogateway',
              iface!,
            ], check: false) ==
            0;
      } else if (await exists('dhclient')) {
        lease =
            await sudo('timeout', [
              '20',
              'dhclient',
              '-1',
              iface!,
            ], check: false) ==
            0;
      }
      if (!lease && (await hostAddressNow()).isEmpty)
        await sudo('ip', ['addr', 'add', hostAddress, 'dev', iface!]);
    }
    await sudo('ip', [
      'route',
      'del',
      'default',
      'via',
      device.host,
      'dev',
      iface!,
    ], check: false);
  }

  Future<bool> answers(int seconds) async {
    for (var attempt = 0; attempt < seconds; attempt++) {
      if ((await capture('ping', ['-c1', '-W1', device.host])).exitCode == 0)
        return true;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  if (action == 'reset') await reset();
  await configure();
  if (!await answers(12)) {
    if (action == 'reset')
      throw BuildFailure('Device does not answer after USB reset');
    await reset();
    await configure();
    if (!await answers(30))
      throw BuildFailure('Device does not answer after USB reset');
  }
  if (share) {
    final wan = await capture('ip', ['route', 'get', '8.8.8.8']);
    if (wan.exitCode != 0 ||
        !RegExp(r'\bdev\s+\S+').hasMatch(wan.stdout.toString()))
      throw BuildFailure('No default route to share');
    if (!await exists('iptables'))
      throw BuildFailure('Internet sharing requires iptables');
    await sudo('sysctl', ['-qw', 'net.ipv4.ip_forward=1']);
    for (final rule in rules()) {
      if (await sudo('iptables', ruleCommand(rule, '-C'), check: false) != 0)
        await sudo('iptables', ruleCommand(rule, '-A'));
    }
    await route(true);
  }
  stdout.writeln(
    'Gadget $iface: ${await hostAddressNow()}; SSH ${device.target}',
  );
  return 0;
}
