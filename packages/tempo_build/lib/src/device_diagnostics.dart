import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:toolbox_core/live_device.dart';
import 'context.dart';
import 'process.dart';

final diagnosticCommands =
    (jsonDecode(r'''{
  "uname.txt": "uname -a; echo; cat /etc/os-release",
  "version.txt": "cat /proc/version",
  "cmdline.txt": "cat /proc/cmdline",
  "config.gz.note.txt": "if [ -r /proc/config.gz ]; then zcat /proc/config.gz; else echo \"no /proc/config.gz (CONFIG_IKCONFIG_PROC off); the config is platform/kernel/config in the repo\"; fi",
  "device-tree.dtb": "cat /sys/firmware/fdt",
  "device-tree.dts": "dtc -q -I fs -O dts /sys/firmware/devicetree/base",
  "device-tree.compatible": "tr \"\\0\" \"\\n\" < /sys/firmware/devicetree/base/compatible; echo \"model: $(tr -d \"\\0\" < /sys/firmware/devicetree/base/model)\"",
  "dmesg.txt": "dmesg",
  "modules.txt": "if [ -s /proc/modules ]; then cat /proc/modules; echo; lsmod; else echo \"(no modules loaded: everything is built into the kernel)\"; fi",
  "iomem.txt": "cat /proc/iomem",
  "interrupts.txt": "cat /proc/interrupts",
  "cpuinfo.txt": "cat /proc/cpuinfo",
  "meminfo.txt": "cat /proc/meminfo",
  "cpus.txt": "echo \"online: $(cat /sys/devices/system/cpu/online)\"; echo \"present: $(cat /sys/devices/system/cpu/present)\"; for c in /sys/devices/system/cpu/cpu[0-9]*; do printf \"%s online=%s\\n\" \"${c##*/}\" \"$(cat $c/online 2>/dev/null || echo boot)\"; done; echo; if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then grep -r . /sys/devices/system/cpu/cpu0/cpufreq/ 2>/dev/null; else echo \"no cpufreq (no driver bound)\"; fi",
  "uptime.txt": "uptime; echo \"loadavg: $(cat /proc/loadavg)\"; echo; free -m",
  "partitions.txt": "cat /proc/partitions",
  "blocks.txt": "lsblk -o NAME,MAJ:MIN,SIZE,RO,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null || lsblk; echo; for b in /sys/block/*; do n=${b##*/}; case $n in loop*|ram*) continue;; esac; printf \"%-12s %12s sectors\" \"$n\" \"$(cat $b/size)\"; [ -r $b/device/name ] && printf \"  %s\" \"$(cat $b/device/name)\"; [ -r $b/device/type ] && printf \" (%s)\" \"$(cat $b/device/type)\"; echo; for p in $b/$n*[0-9]; do [ -f \"$p/partition\" ] && printf \"  %-10s %12s sectors @ %s\\n\" \"${p##*/}\" \"$(cat $p/size)\" \"$(cat $p/start)\"; done; done",
  "mounts.txt": "cat /proc/mounts; echo; df -h",
  "debugfs.txt": "if mountpoint -q /sys/kernel/debug; then ls /sys/kernel/debug; else echo \"debugfs is not mounted (this script does not mount it)\"; fi",
  "gpio.txt": "cat /sys/kernel/debug/gpio 2>/dev/null || echo \"no /sys/kernel/debug/gpio (debugfs not mounted, or CONFIG_DEBUG_FS off)\"",
  "pinctrl.txt": "for f in pinctrl-devices pinctrl-maps pinctrl-handles; do echo \"== $f ==\"; cat /sys/kernel/debug/pinctrl/$f 2>/dev/null || echo \"(absent)\"; echo; done; for d in /sys/kernel/debug/pinctrl/*/; do [ -d \"$d\" ] || continue; for f in pinmux-pins pinconf-pins gpio-ranges; do [ -r \"$d$f\" ] && { echo \"== $d$f ==\"; cat \"$d$f\"; echo; }; done; done",
  "clk_summary.txt": "cat /sys/kernel/debug/clk/clk_summary 2>/dev/null || echo \"no clk_summary (debugfs)\"",
  "clk_orphans.txt": "cat /sys/kernel/debug/clk/clk_orphan_summary 2>/dev/null || echo \"no clk_orphan_summary (debugfs)\"",
  "regulator_summary.txt": "cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null || echo \"no regulator_summary (debugfs)\"; echo; echo \"== supply_map ==\"; cat /sys/kernel/debug/regulator/supply_map 2>/dev/null",
  "pm_genpd.txt": "cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null || echo \"no pm_genpd_summary (debugfs)\"",
  "i2c_devices.txt": "for d in /sys/bus/i2c/devices/*; do [ -e \"$d\" ] || continue; echo \"== $d ==\"; cat \"$d/name\" 2>/dev/null; printf \"driver: \"; readlink \"$d/driver\" 2>/dev/null || echo \"(none)\"; [ -r \"$d/of_node\" ] && printf \"of_node: %s\\n\" \"$(readlink -f $d/of_node)\"; echo; done; echo \"== /sys/kernel/debug/i2c ==\"; find /sys/kernel/debug/i2c -type f 2>/dev/null | while read -r f; do echo \"-- $f\"; cat \"$f\" 2>&1; done",
  "platform_devices.txt": "for d in /sys/bus/platform/devices/*; do printf \"%-40s %s\\n\" \"${d##*/}\" \"$(readlink $d/driver 2>/dev/null | sed \"s|.*/||\")\"; done",
  "devices_deferred.txt": "if [ -r /sys/kernel/debug/devices_deferred ]; then cat /sys/kernel/debug/devices_deferred; [ -s /sys/kernel/debug/devices_deferred ] || echo \"(no devices waiting on probe deferral)\"; else echo \"no devices_deferred (debugfs)\"; fi",
  "sys_class.txt": "ls /sys/class/",
  "dev.txt": "ls -l /dev/",
  "input_devices.txt": "cat /proc/bus/input/devices",
  "usb_gadget.txt": "echo \"== udc ==\"; for u in /sys/class/udc/*; do [ -e \"$u\" ] || continue; echo \"$u\"; for f in state current_speed function is_a_peripheral is_otg maximum_speed; do printf \"  %-16s %s\\n\" \"$f\" \"$(cat $u/$f 2>/dev/null)\"; done; done; echo; echo \"== configfs gadgets ==\"; if [ -d /sys/kernel/config/usb_gadget ] && [ -n \"$(ls -A /sys/kernel/config/usb_gadget 2>/dev/null)\" ]; then grep -r . /sys/kernel/config/usb_gadget 2>/dev/null; else echo \"(none: the gadget is a legacy module or built in, see modules.txt / dmesg)\"; fi; echo; echo \"== /sys/kernel/debug/usb/devices (host side) ==\"; [ -s /sys/kernel/debug/usb/devices ] && cat /sys/kernel/debug/usb/devices || echo \"(no host-side devices)\"; echo; echo \"== lsusb ==\"; lsusb 2>&1; [ -n \"$(lsusb 2>/dev/null)\" ] || echo \"(none)\"",
  "asound.txt": "if [ -d /proc/asound ]; then echo \"== cards ==\"; cat /proc/asound/cards; echo \"== devices ==\"; cat /proc/asound/devices 2>/dev/null; echo \"== pcm ==\"; cat /proc/asound/pcm 2>/dev/null; else echo \"no /proc/asound (no ALSA sound card registered)\"; fi",
  "power_supply.txt": "for p in /sys/class/power_supply/*; do [ -e \"$p\" ] || continue; echo \"== $p ==\"; grep -r . \"$p/\" 2>/dev/null | grep -v \"/uevent:\" | sed \"s|^$p/||\" | sort; cat \"$p/uevent\" 2>/dev/null | sed \"s/^/  uevent: /\"; echo; done",
  "backlight.txt": "for b in /sys/class/backlight/*; do [ -e \"$b\" ] || continue; echo \"== $b ==\"; for f in type brightness actual_brightness max_brightness bl_power scale; do printf \"%-18s %s\\n\" \"$f\" \"$(cat $b/$f 2>/dev/null)\"; done; echo; done",
  "thermal.txt": "for t in /sys/class/thermal/*; do [ -e \"$t\" ] || continue; echo \"== $t ==\"; grep -r . $t/type $t/temp $t/mode $t/cur_state $t/max_state 2>/dev/null; done; [ -n \"$(ls -A /sys/class/thermal 2>/dev/null)\" ] || echo \"no thermal zones\"",
  "rtc.txt": "for r in /sys/class/rtc/*; do [ -e \"$r\" ] || continue; echo \"== $r ==\"; for f in name date time since_epoch wakealarm; do printf \"%-12s %s\\n\" \"$f\" \"$(cat $r/$f 2>/dev/null)\"; done; done; echo; echo \"== hwclock/timedatectl ==\"; timedatectl 2>&1",
  "drm.txt": "echo \"== /sys/class/drm ==\"; ls -l /sys/class/drm; echo; for c in /sys/class/drm/card*-*; do [ -e \"$c\" ] || continue; echo \"== $c ==\"; for f in status enabled dpms modes connector_id; do printf \"%-14s %s\\n\" \"$f\" \"$(cat $c/$f 2>/dev/null | tr \"\\n\" \" \")\"; done; echo \"edid: $(wc -c < $c/edid 2>/dev/null) bytes\"; echo; done; for c in /sys/class/drm/card[0-9]; do [ -e \"$c\" ] || continue; echo \"== $c/device ==\"; cat $c/device/uevent 2>/dev/null; echo; done; echo \"== /sys/kernel/debug/dri ==\"; for d in /sys/kernel/debug/dri/*/; do [ -d \"$d\" ] || continue; for f in name state framebuffer clients; do [ -r \"$d$f\" ] && { echo \"-- $d$f\"; cat \"$d$f\" 2>&1; echo; }; done; done",
  "graphics.txt": "ls -l /sys/class/graphics/ 2>/dev/null; for f in /sys/class/graphics/fb[0-9]*; do [ -e \"$f\" ] || continue; echo \"== $f ==\"; for a in name modes bits_per_pixel virtual_size stride; do printf \"%-16s %s\\n\" \"$a\" \"$(cat $f/$a 2>/dev/null)\"; done; done; [ -e /sys/class/graphics/fb0 ] || echo \"no fb0 (fbdev emulation is off on the cmdline)\"",
  "systemctl_failed.txt": "systemctl --no-pager --failed",
  "services.txt": "systemctl --no-pager --no-legend list-units --type=service --all",
  "units_tempo.txt": "systemctl --no-pager --no-legend list-units --all \"tempo*\" \"tempod*\" \"plymouth*\"; echo; systemctl --no-pager status \"tempo*\" 2>&1 | head -60",
  "journal.txt": "journalctl -b --no-pager -o short-precise",
  "ip.txt": "ip addr; echo; ip route; echo; ip -6 route; echo; cat /etc/hosts",
  "ps.txt": "ps -eo pid,ppid,user,stat,rss,pcpu,args --sort=-rss",
  "tty.txt": "ls -l /dev/ttyS* /dev/ttyGS* /dev/console 2>&1; echo; cat /sys/class/tty/console/active 2>/dev/null"
}''')
            as Map)
        .cast<String, String>();

Future<void> downloadDeviceFile(
  DeviceTransport device,
  String remote,
  File local, {
  bool root = true,
}) async {
  final size = int.parse(
    await device.command(['stat', '-L', '-c', '%s', remote], root: root),
  );
  local.parent.createSync(recursive: true);
  final sink = local.openWrite();
  var received = 0;
  try {
    await for (final bytes in device.read(
      remote,
      offset: 0,
      length: size,
      root: root,
    )) {
      received += bytes.length;
      sink.add(bytes);
    }
  } finally {
    await sink.close();
  }
  if (received != size) throw BuildFailure('Short download of $remote');
}

Future<void> collectSysinfo(
  Repository repo,
  CommandRunner runner,
  SshDeviceTransport device,
) async {
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp(r'[^0-9]'),
    '',
  );
  final remote = '/tmp/tempo-sysinfo-$stamp',
      output = Directory(repo.path('build/toolbox/device/sysinfo-$stamp'));
  await device.command(['true']);
  await device.command(['mkdir', '-m', '755', remote], root: true);
  output.createSync(recursive: true);
  try {
    for (final entry in diagnosticCommands.entries) {
      final path = '$remote/${entry.key}';
      // Keep every command's stderr even when optional device nodes are absent.
      await device.shell(
        'sh -c ${quoteRemote(entry.value)} > ${quoteRemote(path)} 2> ${quoteRemote('$path.err')}; true',
        root: true,
      );
      await downloadDeviceFile(
        device,
        path,
        File(p.join(output.path, entry.key)),
      );
      final errors = int.parse(
        await device.command(['stat', '-c', '%s', '$path.err'], root: true),
      );
      if (errors > 0)
        await downloadDeviceFile(
          device,
          '$path.err',
          File(p.join(output.path, '${entry.key}.err')),
        );
    }
  } finally {
    try {
      await device.command(['rm', '-rf', '--', remote], root: true);
    } on Object {
      /* preserve original failure */
    }
  }
  if (!File(p.join(output.path, 'uname.txt')).existsSync())
    throw BuildFailure('Diagnostics did not produce uname.txt');
  final dtb = File(p.join(output.path, 'device-tree.dtb')),
      dts = File(p.join(output.path, 'device-tree.dts'));
  if ((!dts.existsSync() || dts.lengthSync() == 0) &&
      dtb.existsSync() &&
      dtb.lengthSync() > 0) {
    final args = ['-q', '-I', 'dtb', '-O', 'dts', '-o', dts.path, dtb.path];
    try {
      await runner.run('dtc', args);
    } on Object {
      try {
        await Toolchain(repo, runner).run(['dtc', ...args]);
      } on Object {
        stderr.writeln('No usable dtc; raw device-tree.dtb retained');
      }
    }
  }
  final lines = <String>[];
  final files =
      output
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                !file.path.endsWith('.err') &&
                p.basename(file.path) != 'SHA256SUMS',
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files)
    lines.add(
      '${await sha256.bind(file.openRead()).first}  ${p.basename(file.path)}',
    );
  File(
    p.join(output.path, 'SHA256SUMS'),
  ).writeAsStringSync('${lines.join('\n')}\n');
  stdout.writeln('${files.length} captures: ${output.path}');
}

Future<void> splashDevice(
  Repository repo,
  CommandRunner runner,
  SshDeviceTransport device,
  String action,
) async {
  await device.command(['true']);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  if (action == 'splash-install') {
    final theme = repo.path('platform/splash/plymouth/tempo');
    if (!File(p.join(theme, 'tempo.script')).existsSync())
      throw BuildFailure('Plymouth theme is missing');
    try {
      await device.shell('command -v plymouthd');
    } on DeviceOperationFailure {
      await device.command(['apt-get', 'update'], root: true);
      await device.command([
        'apt-get',
        'install',
        '-y',
        'plymouth',
        'plymouth-themes',
      ], root: true);
    }
    final archive = File(repo.path('build/toolbox/device/theme-$stamp.tar'));
    archive.parent.createSync(recursive: true);
    final remote = '/tmp/tempo-theme-$stamp.tar';
    try {
      await runner.run('tar', ['-C', theme, '-cf', archive.path, '.']);
      await device.upload(archive, remote);
      final local = (await sha256.bind(archive.openRead()).first).toString();
      if (await LiveDeviceOperations(device).checksum(remote) != local)
        throw BuildFailure('Theme transfer checksum mismatch');
      await device.command([
        'rm',
        '-rf',
        '/usr/share/plymouth/themes/tempo',
      ], root: true);
      await device.command([
        'mkdir',
        '-p',
        '/usr/share/plymouth/themes/tempo',
      ], root: true);
      await device.command([
        'tar',
        '-C',
        '/usr/share/plymouth/themes/tempo',
        '-xf',
        remote,
      ], root: true);
      await device.command(['plymouth-set-default-theme', 'tempo'], root: true);
      try {
        await device.shell('command -v update-initramfs');
        await device.command(['update-initramfs', '-u'], root: true);
      } on DeviceOperationFailure {
        stderr.writeln(
          'Device initramfs refresh unavailable; kernel boot-image packaging owns early splash',
        );
      }
    } finally {
      if (archive.existsSync()) archive.deleteSync();
      try {
        await device.command(['rm', '-f', remote]);
      } on Object {
        /* preserve original failure */
      }
    }
    return;
  }
  // Query the actual installed paths and ldd closure; host Dart owns parsing,
  // bounded downloads, staging and configuration instead of a remote script.
  final plugins = (await device.command([
    'find',
    '/usr/lib',
    '-path',
    '*/plymouth/script.so',
  ])).split('\n').where((line) => line.isNotEmpty).toList();
  if (plugins.isEmpty)
    throw BuildFailure('No Plymouth script plugin on device');
  final directory = p.posix.dirname(plugins.first),
      binaries = ['/usr/sbin/plymouthd', '/usr/bin/plymouth'];
  final files = <String>{
    ...binaries,
    '$directory/script.so',
    '$directory/details.so',
    '$directory/renderers/drm.so',
  };
  for (final path in [...files]) {
    final result = await device.command(['ldd', path]);
    files.addAll(
      RegExp(r'/[^\s():]+').allMatches(result).map((match) => match[0]!),
    );
  }
  files.add('/usr/share/plymouth/plymouthd.defaults');
  for (final directory in ['/usr/share/plymouth/themes/tempo', '/etc/plymouth'])
    files.addAll(
      (await device.command([
        'find',
        directory,
        '-type',
        'f',
      ])).split('\n').where((line) => line.isNotEmpty),
    );
  final output = Directory(repo.path('build/os/rootfs/plymouth-payload'));
  final stage = Directory('${output.path}.stage-$stamp')
    ..createSync(recursive: true);
  try {
    for (final remote in files) {
      if (!p.posix.isAbsolute(remote) ||
          p.posix.normalize(remote).contains('/../'))
        throw BuildFailure('Invalid Plymouth path returned by device');
      await downloadDeviceFile(
        device,
        remote,
        File(p.join(stage.path, remote.substring(1))),
        root: false,
      );
      if (binaries.contains(remote))
        await runner.run('chmod', [
          '755',
          p.join(stage.path, remote.substring(1)),
        ]);
    }
    final conf = File(p.join(stage.path, 'etc/plymouth/plymouthd.conf'));
    conf.parent.createSync(recursive: true);
    conf.writeAsStringSync(
      '[Daemon]\nTheme=tempo\nShowDelay=0\nDeviceTimeout=2\n',
    );
    if (output.existsSync()) output.deleteSync(recursive: true);
    stage.renameSync(output.path);
  } finally {
    if (stage.existsSync()) stage.deleteSync(recursive: true);
  }
  stdout.writeln('Plymouth runtime: ${output.path}');
}
