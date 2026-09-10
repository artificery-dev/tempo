import 'dart:io';

import 'process.dart';

/// Captures belong to the originating player, never to a firmware release.
/// Keep this check independent of build timestamps: an old rootfs can otherwise
/// bypass a corrected staging step.
const checkRadioImageScript = r'''
import re, subprocess, sys
image = sys.argv[1]
for path in (
    '/opt/tempo-modem-diag/fixture',
    '/var/log/tempo-modem-bootstrap',
):
    result = subprocess.run(['debugfs', '-R', 'stat ' + path, image],
                            capture_output=True, text=True, check=True)
    if re.search(r'^Inode:\s+\d+', result.stdout, re.MULTILINE):
        raise SystemExit('Refusing to distribute player-specific radio capture: ' + path)
    if 'File not found by ext2_lookup' not in result.stderr:
        raise SystemExit('Could not establish that the rootfs excludes radio captures')
''';

void rejectCapturedRadioBundle(Directory directory) {
  for (final name in ['fs.bin', 'smem.bin']) {
    if (File('${directory.path}/fixture/$name').existsSync()) {
      throw BuildFailure(
        'Cannot package a player-specific radio capture ($name). '
        'Radio initialization must use this player\'s own data; '
        'captured filesystem replies and RAM snapshots are not release assets.',
      );
    }
  }
}
