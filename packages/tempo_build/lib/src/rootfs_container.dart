import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'process.dart';

/// Rootfs mounts run in a private, rootful container mount namespace. The host
/// supplies Dart and Podman; debootstrap, QEMU and filesystem tools are in image.
class RootfsContainer {
  RootfsContainer(this.repo, this.config, this.runner, {this.dartExecutable});
  final String? dartExecutable;
  final Repository repo;
  final BuildConfig config;
  final CommandRunner runner;

  static List<String> arguments({
    required String root,
    required String helper,
    required String configuration,
    required String uid,
    required String gid,
    required List<String> command,
    bool terminal = false,
  }) => [
    'run', '--rm', '-i', if (terminal) '-t',
    '--privileged', '--user', '0:0', '--userns=host',
    // Private propagation keeps image mounts out of the host namespace.
    '-v', '$root:$root:rw,rprivate', '-w', root,
    '-e', 'TEMPO_ROOTFS_HOST=1',
    '-e', 'TEMPO_ROOTFS_LOCK_HELD=1', '-e', 'TEMPO_TOOLCHAIN=1',
    '-e', 'SUDO_UID=$uid', '-e', 'SUDO_GID=$gid',
    'tempo-toolchain', helper, root, configuration, ...command,
  ];

  Future<void> _ensureRootfulImage(String uid, Directory temporary) async {
    // Developer toolchain builds use the caller's image store. Synchronize
    // its exact image into the rootful store rather than silently using an
    // older rootful tag after `toolbox dev toolchain rebuild`.
    if ((await runner.capture('podman', [
          'image',
          'exists',
          'tempo-toolchain',
        ], check: false)).exitCode !=
        0) {
      await Toolchain(repo, runner).build([]);
    }
    if (uid != '0') {
      final source = (await runner.capture('podman', [
        'image',
        'inspect',
        'tempo-toolchain',
        '--format',
        '{{.Id}}',
      ])).stdout.toString().trim();
      final destination = await runner.capture('sudo', [
        'podman',
        'image',
        'inspect',
        'tempo-toolchain',
        '--format',
        '{{.Id}}',
      ], check: false);
      if (destination.exitCode != 0 ||
          destination.stdout.toString().trim() != source) {
        final archive = p.join(temporary.path, 'toolchain.tar');
        await runner.run('podman', [
          'save',
          '--output',
          archive,
          'tempo-toolchain',
        ]);
        await runner.run('sudo', ['podman', 'load', '--input', archive]);
        if (File(archive).existsSync()) File(archive).deleteSync();
      }
    }
  }

  /// Proves the privileges and ARM execution used by the full rootfs builder.
  /// All scratch data lives in the disposable container; no rootfs is opened.
  Future<void> checkPrerequisites() async {
    if (!Platform.isLinux) {
      throw BuildFailure(
        'Full firmware builds require a Linux host with rootful Podman.',
      );
    }
    final busybox = repo.path(
      'platform/rootfs/initramfs/busybox/busybox-armv7l',
    );
    if (!File(busybox).existsSync()) {
      throw BuildFailure('Missing tracked ARM BusyBox prerequisite: $busybox');
    }
    final uid = (await runner.capture('id', ['-u'])).stdout.toString().trim();
    final parent = Directory(repo.path('build/rootfs-container'))
      ..createSync(recursive: true);
    final temporary = parent.createTempSync('prerequisites-');
    try {
      if (uid != '0') {
        // Inherit the terminal so sudo can authenticate normally. Failure here
        // must precede any potentially large image export.
        await runner.run('sudo', ['-v']);
      }
      await _ensureRootfulImage(uid, temporary);
      await runner.run(uid == '0' ? 'podman' : 'sudo', [
        if (uid != '0') 'podman',
        'run',
        '--rm',
        '-i',
        '--privileged',
        '--user',
        '0:0',
        '--userns=host',
        '--network=none',
        '-v',
        '$busybox:/tempo-busybox:ro,rprivate',
        'tempo-toolchain',
        'sh',
        '-ceu',
        prerequisiteScript,
      ]);
    } on BuildFailure catch (error) {
      throw BuildFailure(
        'Rootfs prerequisites failed: rootful Podman must be able to mount an ext4 image and run ARM programs with QEMU. ${error.message}',
        error.code,
      );
    } on ProcessException catch (error) {
      throw BuildFailure(
        'Rootfs prerequisites require working sudo and rootful Podman: $error',
      );
    } finally {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
  }

  static const prerequisiteScript = r'''
for executable in debootstrap chroot mkfs.ext4 e2fsck git systemctl which update-binfmts mount umount; do
  command -v "$executable" >/dev/null || { echo "Missing container prerequisite: $executable" >&2; exit 1; }
done
work=$(mktemp -d /tmp/tempo-rootfs-check.XXXXXX)
mounted=0
cleanup() {
  if [ "$mounted" = 1 ]; then umount "$work/mnt" || return; fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
truncate -s 64M "$work/scratch.ext4"
mkfs.ext4 -q -F "$work/scratch.ext4"
mkdir "$work/mnt"
mount -o loop "$work/scratch.ext4" "$work/mnt"
mounted=1
cp /tempo-busybox "$work/mnt/busybox"
cp /usr/bin/qemu-arm-static "$work/mnt/qemu-arm-static"
chmod 755 "$work/mnt/busybox" "$work/mnt/qemu-arm-static"
chroot "$work/mnt" /qemu-arm-static /busybox true
# A debootstrap shell launches more ARM executables; explicit qemu alone does
# not prove those child execs work. Keep an already-working registration intact.
if ! chroot "$work/mnt" /busybox sh -c '/busybox true' 2>/dev/null; then
  binfmt=/proc/sys/fs/binfmt_misc
  if ! mountpoint -q "$binfmt"; then mount -t binfmt_misc binfmt_misc "$binfmt"; fi
  if [ -e "$binfmt/qemu-arm" ]; then
    # A disabled existing definition can be enabled without changing its magic,
    # interpreter or flags. Never replace any registered emulator.
    if grep -q '^disabled$' "$binfmt/qemu-arm"; then echo 1 > "$binfmt/qemu-arm"; fi
  else
    # Debian's qemu-user-static definition has fix_binary=yes (F): the kernel
    # retains the interpreter after this disposable container exits.
    grep -q '^fix_binary yes$' /usr/share/binfmts/qemu-arm
    update-binfmts --import qemu-arm
    update-binfmts --enable qemu-arm
  fi
fi
chroot "$work/mnt" /busybox sh -c '/busybox true'
umount "$work/mnt"
mounted=0
e2fsck -fn "$work/scratch.ext4"
echo 'Rootfs prerequisites verified: ext4 loop mount, nested ARM execution, clean unmount.'
''';

  Future<int> run(List<String> command) async {
    final uid = (await runner.capture('id', ['-u'])).stdout.toString().trim();
    final gid = (await runner.capture('id', ['-g'])).stdout.toString().trim();
    final prefix = uid == '0' ? <String>[] : ['podman'];
    final executable = uid == '0' ? 'podman' : 'sudo';
    final packages =
        await Isolate.packageConfig ??
        Uri.file(repo.path('.dart_tool/package_config.json'));
    if (packages.scheme != 'file' || !File.fromUri(packages).existsSync()) {
      throw BuildFailure(
        'Rootfs container requires an existing Dart package configuration',
      );
    }
    final dart =
        dartExecutable ??
        (Platform.script.path.endsWith('.dart')
            ? Platform.resolvedExecutable
            : (await FlutterSdk.discover(config, runner)).dart);
    final parent = Directory(repo.path('build/rootfs-container'))
      ..createSync(recursive: true);
    final temporary = parent.createTempSync('invocation-');
    try {
      await runner.run('chmod', ['700', temporary.path]);
      final configuration = File(p.join(temporary.path, 'config.json'));
      configuration.writeAsStringSync(jsonEncode(config.values), flush: true);
      await runner.run('chmod', ['600', configuration.path]);
      final helper = p.join(temporary.path, 'rootfs-builder');
      await runner.run(dart, [
        'compile',
        'exe',
        '--packages=${packages.toFilePath()}',
        repo.path('packages/tempo_build/bin/rootfs_container.dart'),
        '-o',
        helper,
      ]);
      await _ensureRootfulImage(uid, temporary);
      return await runner.run(executable, [
        ...prefix,
        ...arguments(
          root: repo.root,
          helper: helper,
          configuration: configuration.path,
          uid: uid,
          gid: gid,
          command: command,
          terminal: stdin.hasTerminal,
        ),
      ]);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
  }
}
