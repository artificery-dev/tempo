/// Static help is available before repository, SDK, container or device access.
/// Entries describe the implemented parsers, including forwarded arguments.
const developerCommands = <String, (String, String)>{
  'bootstrap': (
    '[--config FILE] [--fixture DIRECTORY] [--build]',
    'Prepare a clean Linux x64 checkout for a complete firmware build.\n'
        'Provision submodules, firmware blobs, pinned SDKs, dependencies, toolchain and CLI.\n'
        '--config imports local settings; --fixture imports private calibration; existing inputs are preserved.\n'
        'Requires Dart, Git, Podman, rootful sudo access and private dependency credentials.\n'
        'From a clean checkout: cd toolbox/cli && dart run bin/toolbox.dart dev bootstrap\n'
        '--build also runs the complete firmware build after setup.',
  ),
  'build': (
    '',
    'Build the complete release firmware in dependency order, ending with build/dist/*.y2-firmware.\n'
        'Requires a bootstrapped Linux x64 checkout and configured local firmware inputs.\n'
        'Rebuilds the configured rootfs image; never accesses or flashes a device.',
  ),
  'app build': (
    '[--release]',
    'Build the device Flutter bundle in build/app. Default: debug/JIT.\n--release adds ARMv7 AOT using the matching pinned engine (Linux x64 host).',
  ),
  'app deploy': (
    '[--release] [--dry-run]',
    'Stage and checksum the built app over SSH, restart and verify with rollback.\n--release selects AOT; --dry-run validates inputs and prints the deployment plan.',
  ),
  'app attach': (
    '[--dry-run]',
    'Attach Flutter to the configured device VM service.\n--dry-run prints the attach command without opening a device connection.',
  ),
  'app clean': (
    '',
    'Remove the Flutter bundle and AOT intermediate; preserve engine/embedder artifacts.',
  ),
  'app flutter-pi engine': (
    '',
    'Fetch the configured engine binaries and matching gen_snapshot into build/app.',
  ),
  'app flutter-pi build': (
    '',
    'Apply the owned embedder patches and cross-build flutter-pi with the toolchain.',
  ),
  'app flutter-pi test': ('', 'Run the embedder native/plugin checks.'),
  'app flutter-pi rev': ('', 'Print the embedder submodule revision.'),
  'app flutter-pi clean': (
    '',
    'Remove the embedder build output; preserve its source and engine binaries.',
  ),
  'daemon build': (
    '[--target host|arm] [--dart-only]',
    'Build the pinned Dart/native-assets bundle in build/os/daemon/TARGET/bundle.\nDefault target: host. arm produces Linux ARM32. --dart-only omits the Rust broker/library.',
  ),
  'daemon deploy': (
    '[--dry-run]',
    'Validate and deploy the complete ARM Dart/native bundle and service units.\n--dry-run checks local inputs without mutating the device.',
  ),
  'daemon test': (
    '[test arguments]',
    'Run native tests, then Dart tests with an isolated SQLite asset map.\nExtra arguments go to package:test from daemon/ (for example test ../packages/player_api/test).',
  ),
  'daemon check': (
    '',
    'Run daemon Dart analysis and native formatting/Clippy checks.',
  ),
  'daemon clean': ('', 'Remove daemon build outputs.'),
  'emulator run': (
    '[Flutter run arguments]',
    'Run the Toolbox emulator with its pinned SDK and emulator-mode define.\nExtra arguments go to flutter run; -d/--device-id selects the target.',
  ),
  'emulator mcp': (
    '[MCP arguments]',
    'Run the emulator VM-service MCP server; extra arguments are forwarded.',
  ),
  'emulator clean': (
    '',
    'Remove emulator-specific cache/VM discovery output; preserve selected mock media folders.',
  ),
  'workspace get': (
    '[pub get arguments]',
    'Resolve workspace and independent package dependencies with their selected SDKs.',
  ),
  'workspace analyze': (
    '[analyzer arguments]',
    'Analyze first-party packages and aggregate failures; arguments are forwarded.',
  ),
  'workspace test': (
    '[test arguments]',
    'Test first-party packages and aggregate failures; arguments are forwarded.',
  ),
  'workspace format': (
    '[dart format arguments]',
    'Format first-party package roots; extra arguments go to dart format.',
  ),
  'toolbox build': (
    '[native|web|cli|linux|macos|windows|apk|ios] [--gui-only] [build arguments]',
    'Build Toolbox with its pinned SDK. Default: native.\n'
        'Native packages the host CLI/helper/GUI resources; web builds Dart/Wasm browser assets.\n'
        '--gui-only builds a desktop GUI and its USB resources without recompiling the CLI.\n'
        'Linux container Flutter output is in build/toolbox/flutter, separate from host/editor caches.\n'
        'Explicit platform targets forward remaining arguments to Flutter build, including --debug and --profile.',
  ),
  'toolbox check': (
    '',
    'Run Toolbox native Rust, Dart/browser and Flutter validation.',
  ),
  'os kernel build': (
    '',
    'Prepare sources, compile the Y2 kernel/DTB, build initramfs and pack BOOTIMG.',
  ),
  'os kernel prepare': (
    '',
    'Verify the committed kernel fork checkout and record source provenance.',
  ),
  'os kernel bootimg': (
    '[--dtb FILE] [--ramdisk FILE] [--output FILE] [--max-size BYTES]',
    'Pack the existing kernel into BOOTIMG and enforce its partition-size limit.\nDefaults come from build/os/kernel, build/os/initramfs and device configuration.',
  ),
  'os kernel rev': ('', 'Print the kernel submodule revision.'),
  'os kernel reset': (
    '',
    'Clear kernel provenance only; refuse uncommitted source changes.',
  ),
  'os kernel clean': (
    '',
    'Remove kernel/initramfs outputs; leave the kernel checkout untouched.',
  ),
  'os rootfs build': (
    '',
    'Build the complete rootfs in a privileged, rootful Linux Podman container.\nRequires sudo/root Podman access; image supplies debootstrap, QEMU and filesystem tools.\nTEMPO_ROOTFS_HOST=1 selects the legacy host-prerequisite path.',
  ),
  'os rootfs stage': (
    '',
    'Stage current runtime, assets, services and configuration into the existing rootfs image.',
  ),
  'os rootfs shell': (
    '[--] [COMMAND arguments]',
    'Open a shell in the rootfs image, or execute the supplied command there.',
  ),
  'os rootfs plan': (
    '',
    'Print the resolved rootfs settings, package count and credential-presence summary.',
  ),
  'os rootfs clean': (
    '',
    'Remove the configured rootfs build output directory; close any host mount first.',
  ),
  'os rootfs stage-plymouth': (
    'TREE OUTPUT',
    'Stage the Plymouth runtime payload from a root filesystem tree into OUTPUT.',
  ),
  'os initramfs build': (
    '',
    'Render and build the configured initramfs payload under build/os/initramfs.',
  ),
  'os initramfs render': (
    '',
    'Render initramfs source/configuration inputs without compiling the kernel.',
  ),
  'os runtime build': (
    '',
    'Cross-compile the Dart rootfs runtime helpers and native bindings for ARM32.',
  ),
  'os bluetooth build': (
    '',
    'Cross-compile the production Dart modem bootstrap and MMIO binding for ARM32.',
  ),
  'os splash build': (
    '[PNG] [--output FILE] [--template FILE] [--index N] [--bare] [--near-black]',
    'Build a MediaTek LOGO image. Defaults: generated boot PNG, stock LOGO template, block 0.\n-o/-t/-i alias output/template/index. --bare creates a one-block image; --near-black adjusts black pixels.',
  ),
  'os splash assets': (
    '',
    'Generate OS splash/Plymouth artwork and the shared core swirl asset together.',
  ),
  'os splash info': (
    'IMAGE',
    'Inspect a MediaTek LOGO image and its block table.',
  ),
  'os splash extract': (
    'IMAGE DIRECTORY',
    'Decode LOGO image blocks into DIRECTORY.',
  ),
  'os splash install': (
    '',
    'Install built splash assets on the live SSH-connected device.',
  ),
  'os splash harvest': (
    '',
    'Collect splash source material from the live SSH-connected device.',
  ),
  'os splash clean': ('', 'Remove generated splash build output.'),
  'diagnostics capture-a2dp': (
    '[BLUETOOTH_ADDRESS] [OUTPUT_DIRECTORY]',
    'Capture a paired peer into a host null sink as 48 kHz stereo signed-16-bit WAV.\nDefault peer: 00:00:46:65:82:01. SIGINT/SIGTERM finalizes the WAV and cleans up the capture.',
  ),
  'diagnostics analyze-tone': (
    'WAV [--silence-db DB] [--minimum-gap-ms MS]',
    'Analyze a solid signed-16-bit PCM tone and print continuity/gap measurements.\nLeading/trailing silence is excluded; music/speech are not valid tone tests.\nDefaults: --silence-db -45 and --minimum-gap-ms 5.\nExit codes: 0 continuous, 1 no active tone, 2 dropouts, 64 invalid input.',
  ),
  'device ssh': (
    '[remote command arguments]',
    'Open SSH to the configured player or run the supplied remote command.\nTEMPO_DEVICE_HOST, TEMPO_DEVICE_USER and TEMPO_SSH_OPTS override connection settings.',
  ),
  'device status': (
    '',
    'Check the live player and report uptime, kernel, network, service and disk state.',
  ),
  'device link': (
    '[up|down|reset] [--share]',
    'Configure the Linux host USB-network link. Default: up. --share enables host Internet sharing.',
  ),
  'device reboot': ('', 'Check the SSH-connected player and request reboot.'),
  'device poweroff': (
    '',
    'Check the SSH-connected player and request poweroff.',
  ),
  'device screenshot': (
    '[NAME]',
    'Capture the player display to build/toolbox/device/screenshots/NAME.png.\nNAME is a filename, not a path; default is timestamped.',
  ),
  'device collect-sysinfo': (
    '',
    'Collect live system diagnostics under build/toolbox/device using SSH.',
  ),
  'device flash-boot': (
    '[IMAGE] [--no-reboot] [--dry-run] [--force]',
    'Install BOOTIMG through the running device with source/target guards.\nDefault image is the built distribution/kernel image. --force permits the existing boot-header override; --no-reboot leaves the player running.',
  ),
  'device flash-logo': (
    '[IMAGE] [--scan] [--dry-run]',
    'Locate and validate the live LOGO partition, back it up, then install the image.\n--scan only locates the existing LOGO and needs no source image.',
  ),
  'device install-rootfs': (
    '[IMAGE] [--sd DIRECTORY | --reboot]',
    'Stage an ext4 or gzip rootfs on the device card, or on a host card with --sd.\nDefault: built distribution rootfs. --reboot is invalid with --sd.',
  ),
  'device splash-install': ('', 'Alias for os splash install.'),
  'device splash-harvest': ('', 'Alias for os splash harvest.'),
  'toolchain build': (
    '[podman build arguments]',
    'Build the configured toolchain container; extra arguments go to podman build.',
  ),
  'toolchain rebuild': (
    '[podman build arguments]',
    'Build the toolchain with --no-cache --pull plus supplied Podman build arguments.',
  ),
  'toolchain run': (
    'COMMAND [arguments]',
    'Execute a command in the shared toolchain container with repository mounts.',
  ),
  'toolchain shell': (
    '[zsh arguments]',
    'Run zsh in the toolchain container with supplied shell arguments.',
  ),
  'toolchain info': (
    '',
    'Inspect the toolchain image and report compiler/device-tree tool versions.',
  ),
  'toolchain clean': ('', 'Remove the tempo-toolchain container image.'),
  'dist': (
    '[--full] [--with-rootfs]',
    'Package the existing kernel, splash and rootfs into an installer .y2-firmware and checksummed SPFT distribution.\n--full also selects stock boot-chain images; the installer always preserves BOOT1.\nDefault preserves preloader/LK/NVRAM. --with-rootfs is accepted for compatibility; rootfs is already required/included.',
  ),
  'config get': (
    'KEY [--raw]',
    'Print a scalar configuration value. This command prints the selected value directly.',
  ),
  'config list': (
    'KEY [--raw]',
    'Print a configured list, one item per line; values are printed directly.',
  ),
  'config json': (
    '[KEY] [--raw]',
    'Print configuration as JSON, redacted by default; --raw includes secret values.',
  ),
  'config has': (
    '[KEY] [--raw]',
    'Exit 0 for a present/nonempty configuration value, 1 for missing or empty; no output.',
  ),
  'secrets status': (
    '',
    'Report local configuration and password/key presence without printing credentials.',
  ),
  'secrets hash': (
    '',
    'Hash a configured plaintext local password using OpenSSL stdin and update file permissions.',
  ),
  'secrets is-hashed': (
    '',
    'Exit 0 if the configured password already has a recognized crypt hash, otherwise 1.',
  ),
};

String developerCommandHelp(List<String> arguments) {
  final words = arguments.where((a) => a != '--help' && a != '-h').toList();
  if (words.isEmpty)
    throw const FormatException('Specify a developer command.');
  var path = '';
  for (final word in words) {
    final candidate = path.isEmpty ? word : '$path $word';
    if (developerCommands.containsKey(candidate)) {
      // A command's remaining tokens are operands/options, not more subcommands.
      final (usage, description) = developerCommands[candidate]!;
      return 'Usage: toolbox dev $candidate${usage.isEmpty ? '' : ' $usage'}\n\n$description\n\nRepository-dependent commands accept --repo PATH. Help needs no checkout or SDK.\n';
    }
    if (!developerCommands.keys.any((key) => key.startsWith('$candidate '))) {
      throw FormatException('Unknown developer command: $candidate');
    }
    path = candidate;
  }
  final children = developerCommands.entries.where(
    (e) => e.key.startsWith('$path '),
  );
  return 'Usage: toolbox dev $path <action> [arguments]\n\n${children.map((e) => '  ${e.key.substring(path.length + 1)}${e.value.$1.isEmpty ? '' : ' ${e.value.$1}'}').join('\n')}\n\nUse toolbox dev $path <action> --help for details. Help needs no checkout or SDK.\n';
}
