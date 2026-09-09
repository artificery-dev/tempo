import 'dart:io';

import 'package:tempo_build/tempo_build.dart';
import 'package:tempo_build/src/toolbox.dart';
import 'package:test/test.dart';

void main() {
  test(
    'private build modes become installable without changing symlink targets',
    () async {
      final temp = Directory.systemTemp.createTempSync('toolbox-modes-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bundle = Directory('${temp.path}/bundle')..createSync();
      final data = Directory('${bundle.path}/data')..createSync();
      final executable = File('${bundle.path}/toolbox')
        ..writeAsStringSync('fixture');
      final resource = File('${data.path}/DA.img')
        ..writeAsStringSync('fixture');
      final external = File('${temp.path}/private')
        ..writeAsStringSync('private');
      final externalDirectory = Directory('${temp.path}/private-directory')
        ..createSync();
      final runner = CommandRunner();
      await runner.run('chmod', [
        '700',
        bundle.path,
        data.path,
        executable.path,
        externalDirectory.path,
      ]);
      await runner.run('chmod', ['600', resource.path, external.path]);
      Link('${bundle.path}/external').createSync(external.path);
      Link(
        '${bundle.path}/external-directory',
      ).createSync(externalDirectory.path);
      await normalizeToolboxPermissions(bundle, runner);
      int mode(String path) => FileStat.statSync(path).mode & 0x1ff;
      expect(mode(bundle.path), 0x1ed);
      expect(mode(data.path), 0x1ed);
      expect(mode(executable.path), 0x1ed);
      expect(mode(resource.path), 0x1a4);
      expect(mode(external.path), 0x180);
      expect(mode(externalDirectory.path), 0x1c0);
      final linkedBundle = Link('${temp.path}/bundle-link')
        ..createSync(bundle.path);
      await expectLater(
        normalizeToolboxPermissions(Directory(linkedBundle.path), runner),
        throwsA(isA<BuildFailure>()),
      );
    },
    skip: Platform.isWindows
        ? 'Unix permission bits; Windows keeps native ACLs'
        : false,
  );
}
