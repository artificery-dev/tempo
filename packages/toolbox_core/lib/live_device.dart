import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class DeviceOperationFailure implements Exception {
  DeviceOperationFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

String quoteRemote(String value) => "'${value.replaceAll("'", "'\\''")}'";

abstract interface class DeviceTransport {
  Future<String> command(List<String> arguments, {bool root = false});
  Future<String> shell(String command, {bool root = false});
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  });
  Future<void> upload(File source, String destination, {bool root = false});
  Future<void> cancel();
}

/// Native SSH adapter. Files are streamed, argv is quoted once for the remote
/// shell, and cancellation kills the active SSH child before another step runs.
class SshDeviceTransport implements DeviceTransport {
  SshDeviceTransport({
    required this.host,
    required this.user,
    List<String>? options,
    this.sshExecutable = 'ssh',
    this.transferIdleTimeout = const Duration(minutes: 2),
    this.killGracePeriod = const Duration(seconds: 2),
  }) : options = [
         ...(options ??
             [
               '-o',
               'BatchMode=yes',
               '-o',
               'StrictHostKeyChecking=no',
               '-o',
               'UserKnownHostsFile=/dev/null',
               '-o',
               'LogLevel=ERROR',
               '-o',
               'ConnectTimeout=10',
             ]),
         '-o',
         'ServerAliveInterval=5',
         '-o',
         'ServerAliveCountMax=3',
       ] {
    if (!RegExp(
      r'^(?:[a-zA-Z0-9:][a-zA-Z0-9._:%-]*|\[[a-fA-F0-9:]+\])$',
    ).hasMatch(host)) {
      throw ArgumentError('Expected an SSH hostname or IP address.');
    }
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$').hasMatch(user)) {
      throw ArgumentError('Expected an SSH account name.');
    }
  }
  final String host, user, sshExecutable;
  final Duration transferIdleTimeout, killGracePeriod;
  final List<String> options;
  final Set<Process> _active = {};
  bool _cancelled = false;
  String get target => '$user@$host';
  bool get isCancelled => _cancelled;

  /// Independent connection for transaction rollback after forward cancellation.
  SshDeviceTransport newConnection() => SshDeviceTransport(
    host: host,
    user: user,
    options: options,
    sshExecutable: sshExecutable,
    transferIdleTimeout: transferIdleTimeout,
    killGracePeriod: killGracePeriod,
  );
  String _command(String command, bool root) => root
      ? '${user == 'root' ? '' : 'sudo -n '}sh -c ${quoteRemote(command)}'
      : command;
  Future<Process> start(String command, {bool root = false}) async {
    if (_cancelled) throw DeviceOperationFailure('Device operation cancelled');
    final child = await Process.start(sshExecutable, [
      ...options,
      target,
      _command(command, root),
    ]);
    _active.add(child);
    unawaited(child.exitCode.then((_) => _active.remove(child)));
    if (_cancelled) {
      await _terminate(child);
      throw DeviceOperationFailure('Device operation cancelled');
    }
    return child;
  }

  Future<void> _terminate(Process child) async {
    child.kill(ProcessSignal.sigterm);
    try {
      await child.exitCode.timeout(killGracePeriod);
    } on TimeoutException {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    }
  }

  Future<String> _output(Process child) async {
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    await child.stdin.close();
    final code = await child.exitCode;
    final text = await output, error = await errors;
    if (code != 0)
      throw DeviceOperationFailure(
        'SSH command failed ($code): ${error.trim()}',
      );
    return text.trim();
  }

  @override
  Future<String> shell(String command, {bool root = false}) async =>
      _output(await start(command, root: root));
  @override
  Future<String> command(List<String> arguments, {bool root = false}) =>
      shell(arguments.map(quoteRemote).join(' '), root: root);
  @override
  Stream<List<int>> read(
    String path, {
    required int offset,
    required int length,
    bool root = false,
  }) async* {
    if (offset < 0 || length < 0)
      throw ArgumentError('Negative device read range');
    final child = await start(
      [
        'dd',
        'if=$path',
        'bs=1048576',
        'iflag=skip_bytes,count_bytes',
        'skip=$offset',
        'count=$length',
        'status=none',
      ].map(quoteRemote).join(' '),
      root: root,
    );
    final errors = child.stderr.transform(utf8.decoder).join();
    await child.stdin.close();
    var received = 0;
    var stalled = false;
    Timer? idle;
    void progress() {
      idle?.cancel();
      idle = Timer(transferIdleTimeout, () {
        stalled = true;
        unawaited(_terminate(child));
      });
    }

    progress();
    try {
      await for (final bytes in child.stdout) {
        progress();
        received += bytes.length;
        if (received > length)
          throw DeviceOperationFailure('Device read exceeded requested range');
        yield bytes;
      }
      final code = await child.exitCode, error = await errors;
      if (stalled) throw DeviceOperationFailure('Device read stalled');
      if (code != 0 || received != length)
        throw DeviceOperationFailure(
          'Short or failed device read: $received/$length bytes ($code) ${error.trim()}',
        );
    } finally {
      idle?.cancel();
      await _terminate(child);
    }
  }

  @override
  Future<void> upload(
    File source,
    String destination, {
    bool root = false,
  }) async {
    final child = await start('cat > ${quoteRemote(destination)}', root: root);
    final output = child.stdout.drain<void>(),
        errors = child.stderr.transform(utf8.decoder).join();
    var stalled = false;
    Timer? idle;
    void progress() {
      idle?.cancel();
      idle = Timer(transferIdleTimeout, () {
        stalled = true;
        unawaited(_terminate(child));
      });
    }

    progress();
    try {
      await child.stdin.addStream(
        source.openRead().map((bytes) {
          progress();
          return bytes;
        }),
      );
      await child.stdin.close();
      final code = await child.exitCode;
      await output;
      final error = await errors;
      if (stalled) throw DeviceOperationFailure('Device upload stalled');
      if (code != 0)
        throw DeviceOperationFailure('Device upload failed ($code): $error');
    } finally {
      idle?.cancel();
      await _terminate(child);
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await Future.wait(_active.toList().map(_terminate));
  }
}

class DeviceGeometry {
  const DeviceGeometry({
    required this.emmcSize,
    required this.bootOffset,
    required this.bootSize,
    required this.logoSize,
    required this.logoScanSize,
  });
  final int emmcSize, bootOffset, bootSize, logoSize, logoScanSize;
}

class LogoLocation {
  const LogoLocation(this.offset, this.bodySize, this.blockCount);
  final int offset, bodySize, blockCount;
  int get imageSize => bodySize + 512;
}

class LiveDeviceOperations {
  LiveDeviceOperations(
    this.transport, {
    void Function(String)? onProgress,
    this.recoveryTransportFactory,
  }) : onProgress = onProgress ?? ((_) {});

  /// Used only for rollback/cleanup, never to resume cancelled forward writes.
  /// SSH connections provide this automatically; other transports can inject it.
  final DeviceTransport Function()? recoveryTransportFactory;
  final DeviceTransport transport;
  final void Function(String) onProgress;
  Future<void> check() => transport.command(['true']);
  Future<void> checkEmmc(DeviceGeometry geometry) async {
    final actual = int.tryParse(
      await transport.command([
        'blockdev',
        '--getsize64',
        '/dev/mmcblk0',
      ], root: true),
    );
    if (actual != geometry.emmcSize)
      throw DeviceOperationFailure(
        'Unexpected eMMC capacity: $actual; expected ${geometry.emmcSize}. Refusing to write.',
      );
  }

  Future<String> checksum(String path) async {
    final result = await transport.command([
      'sha256sum',
      '--',
      path,
    ], root: true);
    final hash = result.split(RegExp(r'\s+')).first;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
      throw DeviceOperationFailure('Invalid device checksum response');
    return hash;
  }

  Future<Uint8List> readBytes(String path, int offset, int length) async {
    final buffer = BytesBuilder();
    await for (final bytes in transport.read(
      path,
      offset: offset,
      length: length,
      root: true,
    ))
      buffer.add(bytes);
    final result = buffer.takeBytes();
    if (result.length != length)
      throw DeviceOperationFailure('Short device read');
    return result;
  }

  Future<String> rangeChecksum(int offset, int length) async {
    var received = 0;
    Stream<List<int>> counted() async* {
      await for (final bytes in transport.read(
        '/dev/mmcblk0',
        offset: offset,
        length: length,
        root: true,
      )) {
        received += bytes.length;
        yield bytes;
      }
    }

    final hash = (await sha256.bind(counted()).first).toString();
    if (received != length)
      throw DeviceOperationFailure('Short device read during checksum');
    return hash;
  }

  Future<void> reboot({bool poweroff = false}) async {
    await transport.shell(
      'sync; sync; nohup sh -c ${quoteRemote('sleep 1; ${poweroff ? 'poweroff' : 'reboot'}')} >/dev/null 2>&1 &',
      root: true,
    );
  }

  Future<void> _verifiedWrite(
    File image,
    int offset, {
    required String name,
    required bool dryRun,
  }) async {
    if (offset < 0 || offset % 4096 != 0)
      throw DeviceOperationFailure('Write offset must be page aligned');
    final local = (await sha256.bind(image.openRead()).first).toString();
    final remote =
        '/tmp/tempo-flash-$name-$pid-${DateTime.now().microsecondsSinceEpoch}.img';
    try {
      onProgress('Uploading $name');
      await transport.upload(image, remote);
      if (await checksum(remote) != local)
        throw DeviceOperationFailure(
          'Transfer checksum mismatch. Nothing written.',
        );
      if (dryRun) {
        onProgress('Transfer verified; dry run leaves eMMC unchanged.');
        return;
      }
      onProgress('Writing $name');
      await transport.command([
        'dd',
        'if=$remote',
        'of=/dev/mmcblk0',
        'bs=4096',
        'seek=${offset ~/ 4096}',
        'conv=fsync',
        'status=none',
      ], root: true);
      await transport.command(['sync'], root: true);
      onProgress('Verifying $name on eMMC');
      if (await rangeChecksum(offset, image.lengthSync()) != local)
        throw DeviceOperationFailure(
          'Read-back mismatch. Do not reboot; restore or flash again.',
        );
    } finally {
      try {
        await transport.command(['rm', '-f', '--', remote]);
      } on Object {
        /* Keep the original transfer failure. */
      }
    }
  }

  Future<void> flashBoot(
    File image,
    DeviceGeometry geometry, {
    bool force = false,
    bool dryRun = false,
    bool rebootAfter = true,
  }) async {
    final input = image.openSync();
    late List<int> magic;
    try {
      magic = input.readSync(8);
    } finally {
      input.closeSync();
    }
    if (!const ListEqualityBytes().equals(magic, ascii.encode('ANDROID!')) ||
        image.lengthSync() > geometry.bootSize)
      throw DeviceOperationFailure('Invalid or oversized Android boot image');
    if (geometry.bootOffset % 4096 != 0 ||
        geometry.bootOffset < 0 ||
        geometry.bootOffset + geometry.bootSize > geometry.emmcSize)
      throw DeviceOperationFailure('Invalid boot partition geometry');
    await check();
    await checkEmmc(geometry);
    final current = await readBytes('/dev/mmcblk0', geometry.bootOffset, 8);
    if (!const ListEqualityBytes().equals(current, ascii.encode('ANDROID!')) &&
        !force)
      throw DeviceOperationFailure(
        'No ANDROID! header at the configured raw offset. Refusing to write blind; --force explicitly overrides.',
      );
    await rangeChecksum(geometry.bootOffset, image.lengthSync());
    await _verifiedWrite(
      image,
      geometry.bootOffset,
      name: 'boot',
      dryRun: dryRun,
    );
    if (!dryRun && rebootAfter) await reboot();
  }

  Future<LogoLocation> locateLogo(DeviceGeometry geometry) async {
    if (geometry.logoScanSize <= 0 || geometry.logoScanSize > geometry.emmcSize)
      throw DeviceOperationFailure('Invalid LOGO scan range');
    final hits = <int>[], tail = <int>[];
    var received = 0;
    await for (final bytes in transport.read(
      '/dev/mmcblk0',
      offset: 0,
      length: geometry.logoScanSize,
      root: true,
    )) {
      final buffer = Uint8List.fromList([...tail, ...bytes]);
      final base = received - tail.length;
      for (var index = 0; index + 12 <= buffer.length; index++) {
        if (buffer[index] == 0x88 &&
            buffer[index + 1] == 0x16 &&
            buffer[index + 2] == 0x88 &&
            buffer[index + 3] == 0x58 &&
            buffer[index + 8] == 76 &&
            buffer[index + 9] == 79 &&
            buffer[index + 10] == 71 &&
            buffer[index + 11] == 79)
          hits.add(base + index);
      }
      tail
        ..clear()
        ..addAll(buffer.skip(buffer.length > 11 ? buffer.length - 11 : 0));
      received += bytes.length;
    }
    if (received != geometry.logoScanSize)
      throw DeviceOperationFailure('Short eMMC LOGO scan');
    if (hits.length != 1)
      throw DeviceOperationFailure(
        'Expected one LOGO header, found ${hits.length}; refusing ambiguous writes',
      );
    final offset = hits.single;
    final header = await readBytes('/dev/mmcblk0', offset, 520);
    final view = ByteData.sublistView(header);
    final body = view.getUint32(4, Endian.little),
        count = view.getUint32(512, Endian.little),
        total = view.getUint32(516, Endian.little);
    final name = ascii.decode(
      header.sublist(8, 40).takeWhile((byte) => byte != 0).toList(),
      allowInvalid: true,
    );
    if (offset % 4096 != 0 ||
        name != 'LOGO' ||
        body <= 8 ||
        body + 512 > geometry.logoSize ||
        offset + geometry.logoSize > geometry.emmcSize ||
        count <= 0 ||
        count >= 256 ||
        total != body)
      throw DeviceOperationFailure(
        'LOGO hit is not page-aligned and plausible',
      );
    return LogoLocation(offset, body, count);
  }

  Future<LogoLocation> flashLogo(
    File? image,
    DeviceGeometry geometry, {
    required File? backup,
    bool scanOnly = false,
    bool dryRun = false,
  }) async {
    if (!scanOnly) {
      if (image == null || backup == null)
        throw ArgumentError('Image and backup required');
      final bytes = image.readAsBytesSync();
      if (bytes.length < 520 || bytes.length > geometry.logoSize)
        throw DeviceOperationFailure('Invalid LOGO image size');
      final view = ByteData.sublistView(bytes);
      if (view.getUint32(0, Endian.little) != 0x58881688 ||
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'LOGO' ||
          view.getUint32(4, Endian.little) + 512 != bytes.length)
        throw DeviceOperationFailure('Invalid LOGO image header');
      if (backup.existsSync())
        throw DeviceOperationFailure(
          'Refusing to overwrite an existing LOGO backup',
        );
    }
    await check();
    await checkEmmc(geometry);
    final location = await locateLogo(geometry);
    if (scanOnly) return location;
    backup!.parent.createSync(recursive: true);
    final bytes = await readBytes(
      '/dev/mmcblk0',
      location.offset,
      location.imageSize,
    );
    if (ByteData.sublistView(bytes).getUint32(0, Endian.little) != 0x58881688)
      throw DeviceOperationFailure('LOGO backup read invalid; nothing written');
    backup.writeAsBytesSync(bytes, flush: true);
    await _verifiedWrite(image!, location.offset, name: 'logo', dryRun: dryRun);
    return location;
  }

  Future<void> deployBundle(
    Directory bundle, {
    required bool release,
    required String destination,
    required String flutterPi,
    required String engineDirectory,
    required String pixelFormat,
    required int vmServicePort,
    bool dryRun = false,
    Duration startupWait = const Duration(seconds: 3),
  }) async {
    if (!bundle.existsSync())
      throw DeviceOperationFailure('App bundle is missing');
    if (File('${bundle.path}/app.so').existsSync() != release) {
      throw DeviceOperationFailure(
        'Bundle mode mismatch; rebuild for the requested deployment mode',
      );
    }
    if (!destination.startsWith('/') ||
        destination
            .split('/')
            .where((part) => part.isNotEmpty && part != '.')
            .isEmpty ||
        destination.split('/').contains('..')) {
      throw DeviceOperationFailure('Unsafe remote app bundle destination');
    }
    destination = destination
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .join('/');
    destination = '/$destination';
    if (vmServicePort < 1 || vmServicePort > 65535)
      throw ArgumentError('Invalid VM service port');
    final files = <File>[];
    for (final entity in bundle.listSync(recursive: true, followLinks: false)) {
      if (entity is Directory) continue;
      final relative = p
          .relative(entity.path, from: bundle.path)
          .replaceAll(Platform.pathSeparator, '/');
      if (entity is! File ||
          RegExp(r'[\x00-\x1f\\]').hasMatch(relative) ||
          relative == '.tempo-deploy.sha256') {
        throw DeviceOperationFailure('Unsupported app bundle file: $relative');
      }
      files.add(entity);
    }
    if (dryRun) {
      onProgress('Would verify and deploy ${bundle.path} to $destination');
      return;
    }
    if (files.isEmpty) throw DeviceOperationFailure('App bundle is empty');
    final id = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final stage = '$destination.stage-$id',
        backup = '$destination.backup-$id',
        lock = '$destination.deploy-lock';
    final remote = '/tmp/tempo-app-deploy-$id.tar.gz',
        launch = '/tmp/tempo-app-deploy-$id.cmdline';
    final directory = Directory.systemTemp.createTempSync('tempo-app-deploy-');
    final snapshot = Directory('${directory.path}/bundle')..createSync();
    final archive = File('${directory.path}/bundle.tar.gz');
    var transaction = transport;
    DeviceTransport? recoveryTransport;
    void beginRecovery() {
      if (recoveryTransport != null) return;
      final source = transport;
      recoveryTransport =
          recoveryTransportFactory?.call() ??
          (source is SshDeviceTransport ? source.newConnection() : source);
      transaction = recoveryTransport!;
    }

    var locked = false,
        stopped = false,
        previous = false,
        wasActive = false,
        wasDebug = false,
        successful = false,
        recovered = false;
    Future<bool> exists(String path) async =>
        await transaction.shell(
          'if [ -e ${quoteRemote(path)} ] || [ -L ${quoteRemote(path)} ]; then printf present; fi',
          root: true,
        ) ==
        'present';
    Future<void> verifyRunning({required bool service}) async {
      await Future<void>.delayed(startupWait);
      await transaction.shell(
        '${service ? 'systemctl is-active --quiet tempo.service && ' : ''}pgrep -ax flutter-pi',
        root: true,
      );
    }

    Future<void> stop() async {
      await transaction.command([
        'systemctl',
        'stop',
        'tempo.service',
      ], root: true);
      await transaction.shell(
        r'''(pkill -x flutter-pi 2>/dev/null || [ "$?" -eq 1 ]) || exit 1; app_wait=0; while pgrep -x flutter-pi >/dev/null; do [ "$app_wait" -lt 20 ] || exit 1; sleep 0.1; app_wait=$((app_wait + 1)); done''',
        root: true,
      );
    }

    Future<void> restore() async {
      await stop();
      if (await exists(backup)) {
        await transaction.command(['rm', '-rf', '--', destination], root: true);
        await transaction.command([
          'mv',
          '-T',
          '--',
          backup,
          destination,
        ], root: true);
      } else if (!previous) {
        await transaction.command(['rm', '-rf', '--', destination], root: true);
      }
      if (wasActive) {
        await transaction.command([
          'systemctl',
          'start',
          'tempo.service',
        ], root: true);
        await verifyRunning(service: true);
      } else if (wasDebug) {
        await transaction.shell(
          'xargs -0 -a ${quoteRemote(launch)} setsid </dev/null >/tmp/tempo.log 2>&1 &',
        );
        await verifyRunning(service: false);
      }
      recovered = true;
    }

    try {
      final manifest = StringBuffer();
      for (final source in files) {
        final relative = p
            .relative(source.path, from: bundle.path)
            .replaceAll(Platform.pathSeparator, '/');
        final copy = File('${snapshot.path}/$relative');
        copy.parent.createSync(recursive: true);
        source.copySync(copy.path);
        manifest.writeln(
          '${await sha256.bind(copy.openRead()).first}  $relative',
        );
      }
      File(
        '${snapshot.path}/.tempo-deploy.sha256',
      ).writeAsStringSync(manifest.toString());
      final packed = await Process.run('tar', [
        '-C',
        snapshot.path,
        '-czf',
        archive.path,
        '.',
      ]);
      if (packed.exitCode != 0)
        throw DeviceOperationFailure(
          'Cannot package app bundle: ${packed.stderr}',
        );
      await transaction.shell(
        'test -x ${quoteRemote(flutterPi)} && test -f ${quoteRemote('$engineDirectory/libflutter_engine.so.${release ? 'release' : 'debug'}')}',
      );
      await transaction.command([
        'mkdir',
        '-p',
        '--',
        destination.substring(0, destination.lastIndexOf('/')).isEmpty
            ? '/'
            : destination.substring(0, destination.lastIndexOf('/')),
      ], root: true);
      await transaction.command(['mkdir', '--', lock], root: true);
      locked = true;
      await transaction.upload(archive, remote);
      if (await checksum(remote) !=
          (await sha256.bind(archive.openRead()).first).toString())
        throw DeviceOperationFailure(
          'App archive transfer checksum mismatch; existing app unchanged',
        );
      await transaction.command([
        'mkdir',
        '-m',
        '755',
        '--',
        stage,
      ], root: true);
      await transaction.command([
        'tar',
        '--no-same-owner',
        '-C',
        stage,
        '-xzf',
        remote,
      ], root: true);
      await transaction.command([
        'chmod',
        '-R',
        'u=rwX,go=rX',
        stage,
      ], root: true);
      await transaction.shell(
        'cd ${quoteRemote(stage)} && sha256sum --strict -c .tempo-deploy.sha256',
        root: true,
      );
      previous = await exists(destination);
      wasActive =
          await transaction.shell(
            'if systemctl is-active --quiet tempo.service; then printf active; fi',
            root: true,
          ) ==
          'active';
      wasDebug =
          !wasActive &&
          await transaction.shell(
                'if pgrep -x flutter-pi >/dev/null; then printf running; fi',
                root: true,
              ) ==
              'running';
      if (wasDebug)
        await transaction.shell(
          'app_pid=\$(pgrep -xo flutter-pi) && cat /proc/"\$app_pid"/cmdline > ${quoteRemote(launch)} && chmod 644 ${quoteRemote(launch)}',
          root: true,
        );
      stopped = true;
      await stop();
      if (previous)
        await transaction.command([
          'mv',
          '-T',
          '--',
          destination,
          backup,
        ], root: true);
      await transaction.command([
        'mv',
        '-T',
        '--',
        stage,
        destination,
      ], root: true);
      if (release) {
        await transaction.command([
          'systemctl',
          'start',
          'tempo.service',
        ], root: true);
      } else {
        await transaction.shell(
          'setsid ${quoteRemote(flutterPi)} --pixelformat ${quoteRemote(pixelFormat)} ${quoteRemote(destination)} --vm-service-port=$vmServicePort --vm-service-host=0.0.0.0 --disable-service-auth-codes </dev/null >/tmp/tempo.log 2>&1 &',
        );
      }
      await verifyRunning(service: release);
      successful = true;
      onProgress('App bundle deployed and startup verified.');
    } catch (error) {
      if (stopped) {
        try {
          beginRecovery();
          onProgress('Restoring the previous app after deployment stopped.');
          await restore();
        } catch (recovery) {
          throw DeviceOperationFailure(
            'App deployment failed: $error. Automatic recovery failed: $recovery. Retain $backup and $launch for recovery.',
          );
        }
        throw DeviceOperationFailure(
          'App deployment failed: $error. Previous bundle and playback process restored.',
        );
      }
      rethrow;
    } finally {
      directory.deleteSync(recursive: true);
      // Cleanup must also work when cancellation happened before stopping the app.
      // A fresh adapter stays private to this transaction until rollback finishes.
      try {
        beginRecovery();
      } catch (error) {
        onProgress('Cannot open deployment cleanup connection: $error');
      }
      Future<void> cleanup(List<String> args, {bool root = false}) async {
        try {
          await transaction.command(args, root: root);
        } catch (_) {}
      }

      await cleanup(['rm', '-f', '--', remote]);
      if (!stopped || successful || recovered) {
        await cleanup(['rm', '-rf', '--', stage], root: true);
        await cleanup(['rm', '-f', '--', launch], root: true);
      }
      if (successful) await cleanup(['rm', '-rf', '--', backup], root: true);
      if (locked) await cleanup(['rmdir', '--', lock], root: true);
      if (recoveryTransport != null &&
          !identical(recoveryTransport, transport)) {
        await recoveryTransport!.cancel();
      }
    }
  }

  Future<void> installRootfs(
    File image,
    String hostname, {
    bool rebootAfter = false,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$').hasMatch(hostname))
      throw ArgumentError('Invalid hostname');
    final input = image.openSync();
    late List<int> magic;
    try {
      magic = input.readSync(2);
    } finally {
      input.closeSync();
    }
    if (image.lengthSync() == 0)
      throw DeviceOperationFailure('Empty rootfs image');
    final name =
            '$hostname.ext4${magic.length == 2 && magic[0] == 0x1f && magic[1] == 0x8b ? '.gz' : ''}',
        destination =
            '/mnt/sd/$hostname.ext4${magic.length == 2 && magic[0] == 0x1f && magic[1] == 0x8b ? '.gz' : ''}';
    await check();
    await transport.command(['mountpoint', '-q', '/mnt/sd']);
    final df = await transport.command(['df', '-Pk', '/mnt/sd']);
    final rows = const LineSplitter().convert(df);
    final available = rows.length < 2
        ? null
        : int.tryParse(rows.last.trim().split(RegExp(r'\s+'))[3]);
    if (available == null || available * 1024 <= image.lengthSync())
      throw DeviceOperationFailure('Not enough free space on the device card');
    final expected = (await sha256.bind(image.openRead()).first).toString();
    onProgress('Copying $name to device card');
    await transport.upload(image, destination, root: true);
    await transport.command(['sync'], root: true);
    if (await checksum(destination) != expected)
      throw DeviceOperationFailure(
        'Card checksum mismatch; reinstall flag was not set',
      );
    await transport.command(['touch', '/mnt/sd/FORCE_REINSTALL'], root: true);
    await transport.command(['sync'], root: true);
    if (rebootAfter) await reboot();
  }
}

class ListEqualityBytes {
  const ListEqualityBytes();
  bool equals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) if (left[i] != right[i]) return false;
    return true;
  }
}
