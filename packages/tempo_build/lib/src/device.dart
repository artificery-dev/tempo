import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:toolbox_core/live_device.dart';
import 'context.dart';
import 'process.dart';
import 'device_link.dart';
import 'device_diagnostics.dart';

SshDeviceTransport deviceTransport(BuildConfig config) => SshDeviceTransport(
  host:
      Platform.environment['TEMPO_DEVICE_HOST'] ??
      config.string('networking.usb_gadget.address').split('/').first,
  user: Platform.environment['TEMPO_DEVICE_USER'] ?? config.string('user.name'),
  options: Platform.environment['TEMPO_SSH_OPTS']
      ?.split(RegExp(r'\s+'))
      .where((arg) => arg.isNotEmpty)
      .toList(),
);
DeviceGeometry deviceGeometry(BuildConfig config) => DeviceGeometry(
  emmcSize: int.parse(config.string('device.partitions.emmc_size')),
  bootOffset: int.parse(config.string('device.partitions.bootimg_offset')),
  bootSize: int.parse(config.string('device.partitions.bootimg_size')),
  logoSize: int.parse(config.string('device.partitions.logo_size')),
  logoScanSize: int.parse(config.string('device.partitions.logo_scan_size')),
);
String timestamp() =>
    DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');

Future<int> deviceCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  if (args.isEmpty || args.first == '--help') {
    stdout.writeln(
      'device ssh|status|link|reboot|poweroff|screenshot|collect-sysinfo|flash-boot|flash-logo|install-rootfs',
    );
    return 0;
  }
  final action = args.removeAt(0), transport = deviceTransport(config);
  final device = LiveDeviceOperations(transport, onProgress: stdout.writeln);
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  if (!Platform.isWindows)
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
      subscriptions.add(
        signal.watch().listen((_) => unawaited(transport.cancel())),
      );
  try {
    if (action == 'link')
      return await deviceLink(config, runner, transport, args);
    if (action == 'ssh')
      return await runner.run('ssh', [
        ...transport.options,
        transport.target,
        ...args,
      ]);
    if (action == 'status') {
      if (args.isNotEmpty) throw BuildFailure('Unexpected status arguments', 2);
      await device.check();
      stdout.writeln('Device: ${transport.target}');
      for (final query in [
        ['hostname'],
        ['uptime'],
        ['uname', '-r'],
        ['cat', '/proc/cmdline'],
        ['ip', '-4', '-o', 'addr', 'show'],
        [
          'systemctl',
          '--no-pager',
          '--no-legend',
          'list-units',
          '--all',
          'tempo*',
          'tempod*',
          'plymouth*',
        ],
        ['df', '-h', '/', '/mnt/sd'],
      ]) {
        try {
          stdout.writeln(await transport.command(query));
        } on DeviceOperationFailure catch (error) {
          stderr.writeln(error);
        }
      }
      return 0;
    }
    if (action == 'reboot' || action == 'poweroff') {
      if (args.isNotEmpty)
        throw BuildFailure('Unexpected $action arguments', 2);
      await device.check();
      await device.reboot(poweroff: action == 'poweroff');
      return 0;
    }
    if (action == 'collect-sysinfo') {
      if (args.isNotEmpty)
        throw BuildFailure('Unexpected collect-sysinfo arguments', 2);
      await collectSysinfo(repo, runner, transport);
      return 0;
    }
    if (action == 'screenshot') {
      if (args.length > 1) throw BuildFailure('Expected screenshot [NAME]', 2);
      final name = args.firstOrNull ?? 'screen-${timestamp()}';
      if (name.contains('/') ||
          name.contains('\\') ||
          name == '.' ||
          name == '..')
        throw BuildFailure('Screenshot name must be a filename', 2);
      final source = File(
            repo.path('platform/diagnostics/device-screenshot.c'),
          ),
          helper = File(repo.path('build/toolbox/device/device-screenshot'));
      helper.parent.createSync(recursive: true);
      if (!helper.existsSync() ||
          helper.lastModifiedSync().isBefore(source.lastModifiedSync()))
        await Toolchain(repo, runner).run([
          'arm-linux-gnueabihf-gcc',
          '-static',
          '-O2',
          '-Wall',
          '-Wextra',
          '-Werror',
          source.path,
          '-o',
          helper.path,
        ]);
      await device.check();
      final remote = '/tmp/tempo-screenshot-${timestamp()}';
      try {
        await transport.upload(helper, remote);
        final local = (await sha256.bind(helper.openRead()).first).toString();
        if (await device.checksum(remote) != local)
          throw BuildFailure('Screenshot helper transfer checksum mismatch');
        await transport.command(['chmod', '755', remote]);
        stdout.writeln(
          await transport.command([remote, '$remote.raw'], root: true),
        );
        final bytes = ByteData.sublistView(
          await device.readBytes('$remote.raw', 0, 480 * 360 * 2),
        );
        final picture = img.Image(width: 480, height: 360, numChannels: 3);
        for (final pixel in picture) {
          final value = bytes.getUint16(
            (pixel.y * 480 + pixel.x) * 2,
            Endian.little,
          );
          pixel.setRgb(
            ((value >> 11) & 31) * 255 ~/ 31,
            ((value >> 5) & 63) * 255 ~/ 63,
            (value & 31) * 255 ~/ 31,
          );
        }
        final output = File(
          repo.path('build/toolbox/device/screenshots/$name.png'),
        );
        output.parent.createSync(recursive: true);
        output.writeAsBytesSync(img.encodePng(picture));
        stdout.writeln(output.path);
      } finally {
        try {
          await transport.command([
            'rm',
            '-f',
            remote,
            '$remote.raw',
          ], root: true);
        } on Object {
          /* original failure retained */
        }
      }
      return 0;
    }
    if (action == 'flash-boot' || action == 'flash-logo') {
      final geometry = deviceGeometry(config),
          allowed = action == 'flash-boot'
              ? {'--no-reboot', '--dry-run', '--force'}
              : {'--scan', '--dry-run'};
      for (final arg in args.where((arg) => arg.startsWith('-')))
        if (!allowed.contains(arg))
          throw BuildFailure('Unknown $action option: $arg', 2);
      final paths = args.where((arg) => !arg.startsWith('-')).toList();
      if (paths.length > 1)
        throw BuildFailure('Only one image may be supplied', 2);
      final scan = args.contains('--scan');
      final candidates = action == 'flash-boot'
          ? ['build/dist/images/boot.img', 'build/os/kernel/boot.img']
          : ['build/dist/images/logo.img', 'build/os/splash/logo.bin'];
      final file = paths.isNotEmpty
          ? File(paths.single)
          : candidates
                .map((path) => File(repo.path(path)))
                .where((file) => file.existsSync())
                .firstOrNull;
      if (file == null && !scan)
        throw BuildFailure('No built image found for $action');
      if (action == 'flash-boot') {
        await device.flashBoot(
          file!,
          geometry,
          force: args.contains('--force'),
          dryRun: args.contains('--dry-run'),
          rebootAfter: !args.contains('--no-reboot'),
        );
      } else {
        final backup = File(
          repo.path('build/toolbox/device/backups/logo-${timestamp()}.bin'),
        );
        final location = await device.flashLogo(
          file,
          geometry,
          backup: scan ? null : backup,
          scanOnly: scan,
          dryRun: args.contains('--dry-run'),
        );
        stdout.writeln(
          'LOGO at 0x${location.offset.toRadixString(16)}, ${location.imageSize} bytes${scan ? '' : '; backup ${backup.path}'}',
        );
      }
      return 0;
    }
    if (action == 'install-rootfs') {
      String? card, imagePath;
      var reboot = false;
      while (args.isNotEmpty) {
        final arg = args.removeAt(0);
        if (arg == '--reboot') {
          reboot = true;
        } else if (arg == '--sd') {
          if (args.isEmpty) throw BuildFailure('--sd requires a directory', 2);
          card = args.removeAt(0);
        } else if (arg.startsWith('--sd=')) {
          card = arg.substring(5);
        } else if (arg.startsWith('-') || imagePath != null) {
          throw BuildFailure('Unexpected install-rootfs argument: $arg', 2);
        } else {
          imagePath = arg;
        }
      }
      if (card != null && reboot)
        throw BuildFailure('--reboot is invalid with a host-side card', 2);
      final image = File(
        imagePath ??
            repo.path(
              'build/dist/images/${config.string('device.hostname')}.ext4.gz',
            ),
      );
      if (card == null) {
        await device.installRootfs(
          image,
          config.string('device.hostname'),
          rebootAfter: reboot,
        );
      } else {
        await installHostCard(
          image,
          card,
          config.string('device.hostname'),
          runner,
        );
      }
      return 0;
    }
    if (action == 'splash-install' || action == 'splash-harvest') {
      if (args.isNotEmpty)
        throw BuildFailure('Unexpected $action arguments', 2);
      await splashDevice(repo, runner, transport, action);
      return 0;
    }
    throw BuildFailure('Unknown device action: $action', 2);
  } finally {
    for (final subscription in subscriptions) await subscription.cancel();
    await transport.cancel();
  }
}

Future<void> installHostCard(
  File image,
  String card,
  String hostname,
  CommandRunner runner,
) async {
  if (!Directory(card).existsSync())
    throw BuildFailure('Card directory does not exist: $card');
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$').hasMatch(hostname))
    throw BuildFailure('Invalid hostname');
  if (image.lengthSync() == 0) throw BuildFailure('Empty rootfs image');
  if ((await runner.capture('mountpoint', [
        '-q',
        card,
      ], check: false)).exitCode !=
      0)
    stderr.writeln('warning: $card is not a mountpoint');
  final disk = (await runner.capture('df', [
    '-Pk',
    card,
  ])).stdout.toString().trim().split('\n').last.trim().split(RegExp(r'\s+'));
  if (disk.length < 4 || int.parse(disk[3]) * 1024 <= image.lengthSync())
    throw BuildFailure('Not enough free space on the card');
  final header = image.openSync();
  late List<int> magic;
  try {
    magic = header.readSync(2);
  } finally {
    header.closeSync();
  }
  final name =
          '$hostname.ext4${magic.length == 2 && magic[0] == 0x1f && magic[1] == 0x8b ? '.gz' : ''}',
      destination = p.join(
        card,
        '$hostname.ext4${magic.length == 2 && magic[0] == 0x1f && magic[1] == 0x8b ? '.gz' : ''}',
      );
  final writable =
      (await runner.capture('test', ['-w', card], check: false)).exitCode == 0;
  Future<int> run(String executable, List<String> args) => runner.run(
    writable ? executable : 'sudo',
    writable ? args : [executable, ...args],
  );
  await run('cp', [image.path, destination]);
  await run('sync', []);
  final hash = (await sha256.bind(image.openRead()).first).toString();
  final cardHash = (await runner.capture(
    writable ? 'sha256sum' : 'sudo',
    writable ? [destination] : ['sha256sum', destination],
  )).stdout.toString().split(RegExp(r'\s+')).first;
  if (hash != cardHash)
    throw BuildFailure('Card checksum mismatch; reinstall flag was not set');
  await run('touch', [p.join(card, 'FORCE_REINSTALL')]);
  await run('sync', []);
  stdout.writeln('Verified $name; FORCE_REINSTALL set on $card');
}
