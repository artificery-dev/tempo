/// CLI presentation only; operation policy remains in toolbox_core.
const endUserHelp = <String, String>{
  'device': '''Usage: toolbox device list|info
Discover a player in MediaTek boot mode. list waits 1 second; info waits 30 seconds.
For a running player's SSH health checks, use toolbox diagnose.''',
  'partitions':
      '''Usage: toolbox partitions [--loader DA.img] [--preloader BOOT1]
Read the powered-off Y2's partition map and identify its address convention.
Waits up to 300 seconds. Does not write storage.''',
  'fetch':
      '''Usage: toolbox fetch NAME OUTPUT [--loader DA.img] [--preloader BOOT1]
Read an anchored vendor partition, boot1 or boot2 into a new file.
Existing output files are refused. RPMB is not exported.''',
  'backup':
      '''Usage: toolbox backup OUTPUT.gz [--resume DIRECTORY] [--loader DA.img] [--preloader BOOT1]
Back up eMMC with checked geometry and bounded streaming.
--resume reuses a verified recovery checkpoint or legacy MTK backup directory.
Connect the powered-off Y2. Existing output files are refused.''',
  'restore':
      '''Usage: toolbox restore INPUT --yes [--resume] [--allow-preloader]
Restore a gzip backup or legacy MTK directory after complete input validation.
--resume compares existing destination chunks before writing.
BOOT1 is preserved unless --allow-preloader is explicit. RPMB is never restored.''',
  'install':
      '''Usage: toolbox install FILE --yes [--resume] [--allow-preloader] [--setup SETUP.json]
Validate a .y2-firmware package, write its declared regions and verify readback.
--resume skips destination chunks only after checksum comparison.
Preloader writes require both package declaration and --allow-preloader.
--setup writes first-run choices into the flashed root filesystem: a JSON
object with any of username, password, hostname, timezone, locale, ssh_keys.
The password is hashed before it is written; the player asks for the rest.''',
  'inspect': '''Usage: toolbox inspect FILE
Validate a .y2-firmware package and report its contents without opening USB.''',
  'inspect-raw': '''Usage: toolbox inspect-raw BOOTIMG|LOGO|BOOT1 FILE
Check a raw image header, size and checksum without opening USB.
BOOT1 inspection requires the wrapped whole hardware-region image.''',
  'install-raw':
      '''Usage: toolbox install-raw BOOTIMG|LOGO FILE SAFETY --dry-run|--yes [--force-boot-header]
Prepare a full-partition safety backup before a guarded raw-image operation.
Actual writes remain disabled pending hardware address validation.
--dry-run validates input, map and safety backup without writing the partition.
--force-boot-header relaxes only the existing BOOTIMG header check.''',
  'doctor': '''Usage: toolbox doctor
Check availability of the bundled native USB engine and download agent.
Does not connect to a player. Exit 69 means required resources are unavailable.''',
  'diagnose': '''Usage: toolbox [--json] diagnose [--host ADDRESS] [--user USER]
Collect read-only system, storage, memory and player-service checks.
Defaults: tempo@10.42.0.1. Requires SSH and an authorized key.
No credentials, settings, media filenames or journal logs are collected.
Exit 0: checks passed; 1: incomplete or needs attention; 130: cancelled.
Use toolbox diagnose --usb instead to probe a player in boot mode.''',
};
