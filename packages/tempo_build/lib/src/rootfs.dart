import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';
import 'bluetooth.dart';
import 'plymouth.dart';
import 'daemon_deploy.dart';
import 'system_runtime.dart';
import 'rootfs_container.dart';

class RootfsImage {
  RootfsImage(this.repo, this.config, this.runner);
  final Repository repo;
  final BuildConfig config;
  final CommandRunner runner;
  String get output => ArtifactPaths(repo).os('rootfs');
  String get image =>
      p.join(output, '${config.string('device.hostname')}.ext4');
  String get mount => p.join(output, 'mnt');
  String at(String relative) {
    final path = p.normalize(
      p.join(mount, relative.replaceFirst(RegExp(r'^/+'), '')),
    );
    if (!p.isWithin(mount, path) && path != mount)
      throw BuildFailure('Path escapes rootfs: $relative');
    return path;
  }

  Future<bool> mounted() async =>
      (await runner.capture('mountpoint', [
        '-q',
        mount,
      ], check: false)).exitCode ==
      0;
  Future<void> open() async {
    Directory(mount).createSync(recursive: true);
    if (await mounted())
      throw BuildFailure(
        'Rootfs is already mounted: $mount; close its existing owner first',
      );
    await runner.run('mount', ['-o', 'loop', image, mount]);
  }

  Future<void> close() async {
    await runner.run('sync', []);
    if (await mounted()) await runner.run('umount', ['-R', mount]);
    if (await mounted())
      throw BuildFailure(
        'Rootfs is still mounted; refusing to check or package it',
      );
    if (Directory(mount).existsSync()) Directory(mount).deleteSync();
  }

  Future<void> check() async {
    final code = await runner.run('e2fsck', ['-pf', image], check: false);
    if (code > 1)
      throw BuildFailure('e2fsck rejected $image (status $code)', code);
  }

  Future<int> chroot(List<String> args, {bool check = true}) async {
    final emulator = File(at('usr/bin/qemu-arm-static'));
    if (!emulator.existsSync())
      File('/usr/bin/qemu-arm-static').copySync(emulator.path);
    return runner.run('chroot', [
      mount,
      '/usr/bin/env',
      'PATH=/usr/sbin:/usr/bin:/sbin:/bin',
      'DEBIAN_FRONTEND=noninteractive',
      'LANG=C.UTF-8',
      'LC_ALL=C.UTF-8',
      ...args,
    ], check: check);
  }

  void remove(String relative) {
    final path = at(relative);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      Link(path).deleteSync();
    } else if (type == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      File(path).deleteSync();
    }
  }

  void write(String relative, String contents) {
    final path = at(relative);
    Directory(p.dirname(path)).createSync(recursive: true);
    if (FileSystemEntity.isLinkSync(path)) Link(path).deleteSync();
    File(path).writeAsStringSync(contents);
  }

  void link(String relative, String target) {
    remove(relative);
    final path = at(relative);
    Directory(p.dirname(path)).createSync(recursive: true);
    Link(path).createSync(target);
  }

  Future<void> mode(String relative, String mode) async =>
      runner.run('chmod', [mode, at(relative)]);
  Future<int> unit(String action, List<String> names, {bool check = true}) =>
      runner.run('systemctl', [
        '--root=$mount',
        '--quiet',
        action,
        ...names,
      ], check: check);
  Future<void> install(
    String source,
    String relative, {
    String mode = '644',
  }) async => runner.run('install', [
    '-D',
    '-m',
    mode,
    '-o',
    '0',
    '-g',
    '0',
    source,
    at(relative),
  ]);

  Future<void> stageOverlay() async {
    final overlay = Directory(repo.path('platform/rootfs/overlay'));
    if (!overlay.existsSync()) return;
    await runner.run('cp', ['-a', '${overlay.path}/.', '$mount/']);
    await runner.run('chown', ['0:0', mount]);
    await mode('', '755');
    for (final entry in overlay.listSync(recursive: true, followLinks: false)) {
      final relative = p.relative(entry.path, from: overlay.path);
      await runner.run('chown', ['-h', '0:0', at(relative)]);
      // Git preserves executable bits, not the checkout's umask. Inheriting
      // a private checkout's modes can make /etc and user-service config
      // inaccessible. Normalize only overlay entries, leaving private image
      // files and symlink targets untouched.
      if (entry is Directory) {
        await mode(relative, '755');
      } else if (entry is File) {
        await mode(relative, entry.statSync().mode & 0x49 != 0 ? '755' : '644');
      }
    }
  }

  Future<void> stageRuntime() async {
    final artifacts = ArtifactPaths(repo);
    final verifiedDaemon = await verifyDaemonBundle(
      repo.path('build/os/daemon/arm/bundle'),
    );
    final runtime = artifacts.os('runtime');
    final runtimeFiles = await verifySystemRuntime(runtime);
    final radio = artifacts.os('bluetooth');
    final manifest = File(p.join(radio, 'build-manifest.json'));
    if (!manifest.existsSync())
      throw BuildFailure(
        'Missing Bluetooth bootstrap; run toolbox dev os bluetooth build',
      );
    final files = jsonDecode(manifest.readAsStringSync()) as Map;
    for (final entry in files.entries) {
      final path = p.normalize(p.join(radio, entry.key as String));
      if (!p.isWithin(radio, path) ||
          (await sha256.bind(File(path).openRead()).first).toString() !=
              entry.value)
        throw BuildFailure(
          'Bluetooth bootstrap artifact changed: ${entry.key}',
        );
    }
    for (final name in runtimeFiles.keys) {
      await install(
        p.join(runtime, name),
        'usr/local/lib/tempo-system/$name',
        mode: name.endsWith('.so') ? '644' : '755',
      );
    }
    for (final name in ['bootstrap', 'mmio.so']) {
      await install(
        p.join(radio, name),
        'opt/tempo-modem-diag/$name',
        mode: name == 'bootstrap' ? '755' : '644',
      );
    }
    for (final file in Directory(
      p.join(radio, 'fixture'),
    ).listSync().whereType<File>())
      await install(
        file.path,
        'opt/tempo-modem-diag/fixture/${p.basename(file.path)}',
        mode: '600',
      );
    await install(
      p.join(radio, 'tempo-modem-bootstrap.service'),
      'etc/systemd/system/tempo-modem-bootstrap.service',
    );
    await unit('enable', ['tempo-modem-bootstrap.service']);
    Future<void> optional(
      String source,
      String target, {
      String mode = '755',
    }) async {
      if (File(source).existsSync()) {
        await install(source, target, mode: mode);
      } else {
        stdout.writeln('Not staged (not built): $source');
      }
    }

    await optional(
      p.join(artifacts.embedder, 'flutter-pi'),
      config.string('flutter.install.flutter_pi'),
    );
    for (final variant in ['debug', 'release'])
      await optional(
        p.join(artifacts.engine, 'arm/libflutter_engine.so.$variant'),
        '${config.string('flutter.install.engine_dir')}/libflutter_engine.so.$variant',
      );
    await optional(
      p.join(artifacts.engine, 'arm/icudtl.dat'),
      config.string('flutter.install.icudtl'),
      mode: '644',
    );
    final bundle = config.string('flutter.install.bundle');
    if (p.posix.normalize(bundle) == '/' || !p.posix.isAbsolute(bundle))
      throw BuildFailure('Unsafe Flutter bundle path: $bundle');
    if (Directory(artifacts.bundle).existsSync()) {
      remove(bundle);
      Directory(at(bundle)).createSync(recursive: true);
      await runner.run('cp', ['-a', '${artifacts.bundle}/.', '${at(bundle)}/']);
      await runner.run('chown', ['-R', '0:0', at(bundle)]);
      await runner.run('chmod', ['-R', 'u=rwX,go=rX', at(bundle)]);
      final icu = File(at(config.string('flutter.install.icudtl')));
      if (icu.existsSync()) icu.copySync(at('$bundle/icudtl.dat'));
    }
    final daemonBundle = verifiedDaemon.directory;
    final manifestFile = File(p.join(daemonBundle, 'manifest.json'));
    remove('usr/local/lib/tempod');
    for (final entry in verifiedDaemon.files.entries) {
      final relative = entry.key;
      await install(
        p.join(daemonBundle, relative),
        'usr/local/lib/tempod/$relative',
        mode: relative.startsWith('bin/') ? '755' : '644',
      );
    }
    await install(manifestFile.path, 'usr/local/lib/tempod/manifest.json');
    link('usr/local/sbin/tempod', '../lib/tempod/bin/tempod');
    final units = repo.path('daemon/systemd');
    for (final name in [
      'tempod.service',
      'tempod-native.service',
      'tempod.socket',
    ]) {
      await install(p.join(units, name), 'etc/systemd/system/$name');
    }
    for (final entry in daemonServiceDropins(config).entries) {
      write(entry.key, entry.value);
    }
    await unit('enable', [
      'tempod.socket',
      'tempod-native.service',
      'tempod.service',
    ]);
  }
}

/// Serialize image owners across private container mount namespaces. The lock
/// sits outside rootfs output so clean cannot delete its own synchronization.
Future<T> withRootfsLock<T>(
  Repository repo,
  Future<T> Function() operation,
) async {
  final directory = Directory(repo.path('build/rootfs-container'))
    ..createSync(recursive: true);
  final handle = File(
    p.join(directory.path, 'image.lock'),
  ).openSync(mode: FileMode.append);
  var locked = false;
  try {
    try {
      await handle.lock(FileLock.exclusive);
      locked = true;
    } on FileSystemException {
      throw BuildFailure(
        'Another rootfs operation owns this checkout; wait for it to finish',
        73,
      );
    }
    return await operation();
  } finally {
    if (locked) await handle.unlock();
    await handle.close();
  }
}

Future<int> rootfsCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) {
  final action = args.firstOrNull ?? 'plan';
  if (Platform.environment['TEMPO_ROOTFS_LOCK_HELD'] == '1' ||
      !['build', 'stage', 'shell', 'clean'].contains(action)) {
    return _rootfsCommand(repo, config, runner, args);
  }
  return withRootfsLock(repo, () => _rootfsCommand(repo, config, runner, args));
}

Future<int> _rootfsCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  final action = args.isEmpty ? 'plan' : args.removeAt(0);
  final image = RootfsImage(repo, config, runner);
  if (action == 'plan') {
    if (args.isNotEmpty)
      throw BuildFailure('Unexpected rootfs plan arguments', 2);
    for (final key in [
      'device.hostname',
      'user.name',
      'user.uid',
      'user.gid',
      'user.groups',
      'rootfs.suite',
      'rootfs.arch',
      'rootfs.size_mb',
      'rootfs.label',
      'rootfs.locale',
      'rootfs.timezone',
      'rootfs.permit_root_login',
      'networking',
      'firewall',
      'flutter.install',
      'daemon.socket',
    ])
      stdout.writeln('$key: ${jsonEncode(config.get(key))}');
    final groups = config.get('rootfs.packages') as Map;
    stdout.writeln(
      'packages: ${groups.values.whereType<List>().fold(0, (count, entries) => count + entries.length)} across ${groups.length} groups',
    );
    stdout.writeln(
      'credentials: password ${(config.get('user.password')?.toString() ?? '').isEmpty ? 'unset' : 'set'}, ${(config.get('user.ssh_keys') as List?)?.length ?? 0} SSH keys',
    );
    return 0;
  }
  if (action == 'stage-plymouth') {
    if (args.length != 2)
      throw BuildFailure('Expected rootfs stage-plymouth TREE OUTPUT', 2);
    await stagePlymouth(args[0], args[1], runner);
    return 0;
  }
  if (!['build', 'stage', 'shell', 'clean'].contains(action))
    throw BuildFailure(
      'Expected rootfs build, stage, shell, clean, plan, or stage-plymouth',
      2,
    );
  if (action != 'shell' && args.isNotEmpty)
    throw BuildFailure('Unexpected rootfs $action arguments', 2);
  if (!Platform.isLinux)
    throw BuildFailure('Rootfs loop mounting and chroot require a Linux host');
  if (action == 'clean' && !Directory(image.output).existsSync()) return 0;
  if (['stage', 'shell'].contains(action) && !File(image.image).existsSync())
    throw BuildFailure('Missing rootfs image: ${image.image}');
  if (Platform.environment['TEMPO_ROOTFS_HOST'] != '1' &&
      Platform.environment['TEMPO_TOOLCHAIN'] != '1') {
    if (await image.mounted()) {
      throw BuildFailure(
        'Rootfs image is mounted on the host; close its owner before container use',
      );
    }
    if (action == 'build' || action == 'stage') {
      Directory(image.output).createSync(recursive: true);
      await bluetoothCommand(repo, config, runner, ['build']);
      await systemRuntimeCommand(repo, config, runner, ['build']);
    }
    return RootfsContainer(repo, config, runner).run([action, ...args]);
  }
  final uid = (await runner.capture('id', ['-u'])).stdout.toString().trim();
  if (uid != '0') {
    if (action == 'build' || action == 'stage') {
      Directory(image.output).createSync(recursive: true);
      await bluetoothCommand(repo, config, runner, ['build']);
      await systemRuntimeCommand(repo, config, runner, ['build']);
    }
    final packageConfig = await Isolate.packageConfig;
    final executable = Platform.script.path.endsWith('.dart')
        ? Platform.resolvedExecutable
        : (await FlutterSdk.discover(config, runner)).dart;
    final command = <String>[
      executable,
      if (packageConfig != null) '--packages=${packageConfig.toFilePath()}',
      repo.path('packages/tempo_build/bin/tempo_build.dart'),
      '--repo',
      repo.root,
      'os',
      'rootfs',
      action,
      ...args,
    ];
    return runner.run(
      'sudo',
      ['-E', ...command],
      environment: {
        'TEMPO_CONFIG_HOME': Platform.environment['HOME'] ?? '',
        'TEMPO_ROOTFS_LOCK_HELD': '1',
      },
    );
  }
  if (action == 'clean') {
    if (await image.mounted()) await runner.run('umount', ['-R', image.mount]);
    Directory(image.output).deleteSync(recursive: true);
    return 0;
  }
  if (action == 'build') {
    await buildRootfs(image);
    return 0;
  }
  await image.open();
  try {
    if (action == 'stage') {
      await image.stageRuntime();
    } else {
      for (final entry in [('proc', 'proc', 'proc'), ('sysfs', 'sysfs', 'sys')])
        await runner.run('mount', [
          '-t',
          entry.$1,
          entry.$2,
          image.at(entry.$3),
        ]);
      for (final directory in ['dev', 'dev/pts'])
        await runner.run('mount', [
          '--bind',
          '/$directory',
          image.at(directory),
        ]);
      final resolv = image.at('etc/resolv.conf');
      final link = FileSystemEntity.isLinkSync(resolv)
          ? Link(resolv).targetSync()
          : null;
      final previous = link == null && File(resolv).existsSync()
          ? File(resolv).readAsBytesSync()
          : null;
      image.remove('etc/resolv.conf');
      File('/etc/resolv.conf').copySync(resolv);
      try {
        if (args.firstOrNull == '--') args.removeAt(0);
        await image.chroot(args.isEmpty ? ['/bin/bash', '-l'] : args);
      } finally {
        image.remove('etc/resolv.conf');
        if (link != null)
          image.link('etc/resolv.conf', link);
        else if (previous != null)
          File(resolv).writeAsBytesSync(previous);
        image.remove('usr/bin/qemu-arm-static');
      }
    }
  } finally {
    await image.close();
  }
  if (action == 'stage') await image.check();
  return 0;
}

Future<void> buildRootfs(RootfsImage image) async {
  final config = image.config, runner = image.runner, repo = image.repo;
  String get(String key) => config.string(key);
  bool enabled(String key) => config.get(key) == true;
  List<String> list(String key) => (config.get(key) as List? ?? [])
      .map((value) => value.toString())
      .toList();
  final user = get('user.name'), uid = get('user.uid'), gid = get('user.gid');
  if (!RegExp(r'^[a-z_][a-z0-9_-]*$').hasMatch(user) || user == 'root')
    throw BuildFailure('Rootfs requires an unprivileged Unix user name');
  final password = config.get('user.password')?.toString() ?? '';
  final keys = list('user.ssh_keys');
  if (password.isEmpty && keys.isEmpty)
    throw BuildFailure(
      'No credentials configured for $user; set user.password or user.ssh_keys in config.local.yaml',
    );
  var hash = password;
  if (password.isNotEmpty &&
      !RegExp(r'^\$(y|gy|7|2[abxy]|6|5|1)\$').hasMatch(password)) {
    final process = await Process.start('openssl', ['passwd', '-6', '-stdin']);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    process.stdin.write(password);
    await process.stdin.close();
    final code = await process.exitCode;
    hash = (await output).trim();
    await errors;
    if (code != 0 || !hash.startsWith(r'$6$'))
      throw BuildFailure('Password hashing failed');
  }
  for (final executable in [
    'debootstrap',
    'chroot',
    'mkfs.ext4',
    'e2fsck',
    'git',
    'systemctl',
  ]) {
    if ((await runner.capture('which', [executable], check: false)).exitCode !=
        0)
      throw BuildFailure('Missing rootfs host prerequisite: $executable');
  }
  if (!File('/usr/bin/qemu-arm-static').existsSync())
    throw BuildFailure('Missing /usr/bin/qemu-arm-static');
  if (await image.mounted())
    throw BuildFailure(
      'Rootfs image is already mounted; close its owner before rebuilding',
    );
  final size = int.tryParse(get('rootfs.size_mb'));
  if (size == null ||
      size <= 0 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$').hasMatch(get('device.hostname')))
    throw BuildFailure('Invalid rootfs image size or hostname');
  Directory(image.output).createSync(recursive: true);
  if (File(image.image).existsSync()) File(image.image).deleteSync();
  final imageFile = File(image.image).openSync(mode: FileMode.write);
  try {
    imageFile.truncateSync(size * 1024 * 1024);
  } finally {
    imageFile.closeSync();
  }
  await runner.run('mkfs.ext4', [
    '-q',
    '-L',
    get('rootfs.label'),
    '-O',
    '^metadata_csum_seed',
    image.image,
  ]);
  await image.open();
  try {
    await runner.run('debootstrap', [
      '--arch=${get('rootfs.arch')}',
      '--foreign',
      '--variant=minbase',
      '--include=${list('rootfs.packages.bootstrap').join(',')}',
      get('rootfs.suite'),
      image.mount,
      get('rootfs.mirror'),
    ]);
    // Temporary Debian package-manager protocol hook, never a shipped service.
    // Package configuration must not start target daemons on the build host.
    image.write('usr/sbin/policy-rc.d', '#!/bin/sh\nexit 101\n');
    await image.mode('usr/sbin/policy-rc.d', '755');
    await runner.run('mount', ['-t', 'proc', 'proc', image.at('proc')]);
    Directory(image.at('dev/pts')).createSync(recursive: true);
    await runner.run('mount', ['-t', 'devpts', 'devpts', image.at('dev/pts')]);
    await image.chroot(['/debootstrap/debootstrap', '--second-stage']);
    // debootstrap removes its temporary policy after the second stage.
    // Re-establish the guard for the larger application package installation.
    image.write('usr/sbin/policy-rc.d', '#!/bin/sh\nexit 101\n');
    await image.mode('usr/sbin/policy-rc.d', '755');
    // Its cleanup also unmounts proc/devpts; later package scripts need them.
    for (final entry in {'proc': 'proc', 'dev/pts': 'devpts'}.entries) {
      if ((await runner.capture('mountpoint', [
            '-q',
            image.at(entry.key),
          ], check: false)).exitCode !=
          0) {
        await runner.run('mount', [
          '-t',
          entry.value,
          entry.value,
          image.at(entry.key),
        ]);
      }
    }
    image.write('etc/hostname', '${get('device.hostname')}\n');
    image.write(
      'etc/hosts',
      '127.0.0.1\tlocalhost\n127.0.1.1\t${get('device.hostname')}\n',
    );
    image.link(
      'etc/localtime',
      '/usr/share/zoneinfo/${get('rootfs.timezone')}',
    );
    image.write('etc/timezone', '${get('rootfs.timezone')}\n');
    image.write(
      'etc/fstab',
      '# <file system> <mount point> <type> <options> <dump> <pass>\nproc /proc proc defaults 0 0\n',
    );
    image.write(
      'etc/resolv.conf',
      'nameserver ${list('networking.dns').first}\n',
    );
    await image.chroot(['apt-get', 'update']);
    await image.chroot([
      'apt-get',
      'install',
      '-y',
      '--no-install-recommends',
      for (final group in ['system', 'graphics', 'audio', 'bluetooth', 'tools'])
        ...list('rootfs.packages.$group'),
    ]);
    image.write('etc/locale.gen', '${get('rootfs.locale')} UTF-8\n');
    await image.chroot(['locale-gen']);
    await image.chroot(['update-locale', 'LANG=${get('rootfs.locale')}']);
    await image.chroot(['groupadd', '-g', gid, user], check: false);
    await image.chroot([
      'useradd',
      '-m',
      '-u',
      uid,
      '-g',
      gid,
      '-c',
      get('user.gecos'),
      '-s',
      get('user.shell'),
      user,
    ]);
    for (final group in list('user.groups')) {
      if (await image.chroot(['getent', 'group', group], check: false) == 0) {
        await image.chroot(['usermod', '-aG', group, user]);
      } else if (['video', 'render', 'input'].contains(group)) {
        throw BuildFailure('Required runtime group is missing: $group');
      } else {
        stdout.writeln('Optional group not installed: $group');
      }
    }
    if (hash.isEmpty) {
      await image.chroot(['passwd', '-l', user]);
    } else {
      // Feed hashes via stdin so they are absent from argv/process listings.
      await runner.run('chroot', [
        image.mount,
        '/usr/sbin/chpasswd',
        '-e',
      ], input: Stream.value(utf8.encode('$user:$hash\n')));
    }
    await image.chroot(['passwd', '-l', 'root']);
    image.remove('etc/sudoers.d/10-tempo');
    if (enabled('user.sudoer')) {
      await image.chroot(['usermod', '-aG', 'sudo', user]);
      if (enabled('user.passwordless_sudo')) {
        image.write(
          'etc/sudoers.d/10-tempo',
          '# Generated from config.yaml\n$user ALL=(ALL:ALL) NOPASSWD: ALL\n',
        );
        await image.mode('etc/sudoers.d/10-tempo', '440');
        await image.chroot([
          'visudo',
          '-c',
          '-q',
          '-f',
          '/etc/sudoers.d/10-tempo',
        ]);
      }
    }
    if (keys.isNotEmpty) {
      image.write('home/$user/.ssh/authorized_keys', '${keys.join('\n')}\n');
      await image.mode('home/$user/.ssh', '700');
      await image.mode('home/$user/.ssh/authorized_keys', '600');
      await runner.run('chown', [
        '-R',
        '$uid:$gid',
        image.at('home/$user/.ssh'),
      ]);
    }
    image.write(
      'etc/ssh/sshd_config.d/10-tempo.conf',
      'PermitRootLogin ${enabled('rootfs.permit_root_login') ? 'yes' : 'no'}\nPasswordAuthentication yes\n',
    );
    await image.unit('enable', ['ssh.service'], check: false);
    for (final file in Directory(image.at('etc/ssh')).listSync().where(
      (entry) => p.basename(entry.path).startsWith('ssh_host_'),
    ))
      image.remove(p.relative(file.path, from: image.mount));
    image.write(
      'etc/systemd/system/getty@tty1.service.d/autologin.conf',
      '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin $user --noclear %I \$TERM\n',
    );
    image.write(
      'etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf',
      '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin $user --keep-baud 115200,38400,9600 %I \$TERM\n[Unit]\nStartLimitIntervalSec=0\n',
    );
    for (final service in [
      'serial-getty@ttyGS0',
      'systemd-networkd',
      'systemd-resolved',
      'systemd-timesyncd',
    ])
      await image.unit('enable', ['$service.service'], check: false);
    await image.unit('mask', [
      'systemd-networkd-wait-online.service',
    ], check: false);
    final usb = get('networking.usb_gadget.interface'),
        wifi = get('networking.wifi.interface');
    image.write(
      'etc/systemd/network/10-$usb.network',
      '[Match]\nName=$usb\n\n[Network]\nAddress=${get('networking.usb_gadget.address')}\n${enabled('networking.usb_gadget.dhcp_server') ? 'DHCPServer=yes\n' : ''}',
    );
    image.write(
      'etc/systemd/network/25-$wifi.network',
      '[Match]\nName=$wifi\n\n[Network]\nDHCP=yes\nIPv6AcceptRA=yes\n\n[DHCPv4]\nRouteMetric=50\n',
    );
    image.write(
      'etc/wpa_supplicant/wpa_supplicant-nl80211-$wifi.conf',
      'ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev\nupdate_config=1\n',
    );
    await image.mode(
      'etc/wpa_supplicant/wpa_supplicant-nl80211-$wifi.conf',
      '600',
    );
    image.write(
      'etc/systemd/resolved.conf.d/10-tempo.conf',
      '[Resolve]\nDNS=${list('networking.dns').join(' ')}\nMulticastDNS=no\n',
    );
    await image.unit(
      enabled('networking.mdns.enabled') ? 'enable' : 'disable',
      ['avahi-daemon.service'],
      check: false,
    );
    if (enabled('networking.mdns.enabled')) {
      final nss = File(image.at('etc/nsswitch.conf'));
      final contents = nss
          .readAsStringSync()
          .split('\n')
          .map((line) {
            if (!line.startsWith('hosts:')) return line;
            return line
                .replaceAll(
                  RegExp(r' *mdns4_minimal( \[NOTFOUND=return\])?'),
                  '',
                )
                .replaceFirstMapped(
                  RegExp(r'^(hosts:\s*files)'),
                  (match) => '${match[1]} mdns4_minimal [NOTFOUND=return]',
                );
          })
          .join('\n');
      if (!RegExp(
        r'^hosts:\s+files mdns4_minimal \[NOTFOUND=return\]',
        multiLine: true,
      ).hasMatch(contents))
        throw BuildFailure('Cannot configure mDNS resolver precedence');
      nss.writeAsStringSync(contents);
    }
    if (enabled('firewall.enabled')) {
      // Never enable a live firewall in the chroot: that would affect the host.
      for (final name in ['iptables', 'ip6tables'])
        await image.chroot([
          'update-alternatives',
          '--quiet',
          '--set',
          name,
          '/usr/sbin/$name-legacy',
        ]);
      try {
        await image.chroot([
          'ufw',
          'default',
          get('firewall.default_incoming'),
          'incoming',
        ]);
        await image.chroot([
          'ufw',
          'default',
          get('firewall.default_outgoing'),
          'outgoing',
        ]);
        for (final iface in list('firewall.trusted_interfaces'))
          await image.chroot(['ufw', 'allow', 'in', 'on', iface]);
        for (final rule in list('firewall.allow'))
          await image.chroot(['ufw', 'allow', rule]);
      } finally {
        for (final name in ['iptables', 'ip6tables'])
          await image.chroot([
            'update-alternatives',
            '--quiet',
            '--auto',
            name,
          ]);
      }
      final ufw = File(image.at('etc/ufw/ufw.conf'));
      final contents = ufw.readAsStringSync().replaceAll(
        RegExp(r'^ENABLED=.*$', multiLine: true),
        'ENABLED=yes',
      );
      ufw.writeAsStringSync(
        contents.contains('ENABLED=yes')
            ? contents
            : '$contents\nENABLED=yes\n',
      );
      await image.unit('enable', ['ufw.service'], check: false);
      final rules = File(image.at('etc/ufw/user.rules')).readAsStringSync();
      for (final iface in list('firewall.trusted_interfaces'))
        if (!rules.contains('-i $iface -j ACCEPT'))
          throw BuildFailure(
            'Firewall trust rule is missing for $iface; refusing to ship a deny policy',
          );
    }
    if (enabled('shell.setup_oh_my_zsh')) {
      final cache = p.join(image.output, '.omz-cache');
      if (!Directory(cache).existsSync()) {
        await runner.run('git', [
          'clone',
          '-q',
          '--depth',
          '1',
          'https://github.com/ohmyzsh/ohmyzsh.git',
          cache,
        ]);
        Directory(p.join(cache, '.git')).deleteSync(recursive: true);
      }
      for (final account in [('home/$user', uid, gid), ('root', '0', '0')]) {
        await runner.run('cp', [
          '-a',
          cache,
          image.at('${account.$1}/.oh-my-zsh'),
        ]);
        image.write(
          '${account.$1}/.zshrc',
          'export ZSH="\$HOME/.oh-my-zsh"\nZSH_THEME=${shellQuote(get('shell.oh_my_zsh_theme'))}\nplugins=(${list('shell.oh_my_zsh_plugins').map(shellQuote).join(' ')})\nsource \$ZSH/oh-my-zsh.sh\n',
        );
        await runner.run('chown', [
          '-R',
          '${account.$2}:${account.$3}',
          image.at('${account.$1}/.oh-my-zsh'),
          image.at('${account.$1}/.zshrc'),
        ]);
      }
    }
    final theme = Directory(repo.path('platform/splash/plymouth/tempo'));
    if (theme.existsSync()) {
      Directory(
        image.at('usr/share/plymouth/themes/tempo'),
      ).createSync(recursive: true);
      await runner.run('cp', [
        '-r',
        '${theme.path}/.',
        '${image.at('usr/share/plymouth/themes/tempo')}/',
      ]);
      await runner.run('chown', [
        '-R',
        '0:0',
        image.at('usr/share/plymouth/themes/tempo'),
      ]);
      await image.chroot(['plymouth-set-default-theme', 'tempo']);
      final payload = p.join(image.output, 'plymouth-payload');
      await stagePlymouth(image.mount, payload, runner);
      final callerUid = Platform.environment['SUDO_UID'],
          callerGid = Platform.environment['SUDO_GID'];
      if (callerUid != null && callerGid != null)
        await runner.run('chown', ['-R', '$callerUid:$callerGid', payload]);
    }
    final overlay = Directory(repo.path('platform/rootfs/overlay'));
    if (overlay.existsSync()) {
      await image.stageOverlay();
      image.write(
        'etc/systemd/system/tempo.service.d/10-user.conf',
        '[Unit]\nWants=user@$uid.service\nAfter=user@$uid.service\n\n[Service]\nUser=$user\nGroup=$user\nEnvironment=XDG_RUNTIME_DIR=/run/user/$uid\nEnvironment=LD_PRELOAD=/usr/lib/arm-linux-gnueabihf/libsqlite3.so.0\nEnvironment=PIPEWIRE_CONFIG_NAME=client-rt.conf\nLimitRTPRIO=95\nLimitNICE=-19\nLimitMEMLOCK=4194304\n',
      );
      image.write('var/lib/systemd/linger/$user', '');
      for (final service in [
        'tempo',
        'tempo-clear-reinstall-flag',
        'tempo-ssh-hostkeys',
        'mt6582-wifi-power',
        'wpa_supplicant-nl80211@$wifi',
      ])
        await image.unit('enable', ['$service.service'], check: false);
      await image.unit('mask', ['plymouth-quit.service'], check: false);
      Directory(image.at('mnt/sd')).createSync(recursive: true);
    }
    await image.stageRuntime();
    await image.chroot(['apt-get', 'clean']);
    for (final directory in ['var/lib/apt/lists', 'var/cache/apt/archives']) {
      final path = Directory(image.at(directory));
      if (path.existsSync())
        for (final entry in path.listSync())
          if (directory.endsWith('lists') || entry.path.endsWith('.deb'))
            image.remove(p.relative(entry.path, from: image.mount));
    }
    image.remove('usr/bin/qemu-arm-static');
    image.remove('usr/sbin/policy-rc.d');
    image.link('etc/resolv.conf', '/run/systemd/resolve/stub-resolv.conf');
    image.write('etc/machine-id', '');
    image.link('var/lib/dbus/machine-id', '/etc/machine-id');
  } finally {
    await image.close();
  }
  await image.check();
  final callerUid = Platform.environment['SUDO_UID'];
  final callerGid = Platform.environment['SUDO_GID'];
  if (callerUid != null && callerGid != null) {
    await runner.run('chown', [
      '$callerUid:$callerGid',
      image.output,
      image.image,
    ]);
  }
  stdout.writeln('Rootfs image: ${image.image}');
}
