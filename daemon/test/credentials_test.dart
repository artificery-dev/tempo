import 'dart:io';
import 'package:tempod/src/services/credentials.dart';
import 'package:test/test.dart';

void main() {
  test(
    'first boot creates distinct private tokens and preserves them on restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tempod-credentials-',
      );
      try {
        await initializeCredentials(directory.path);
        final api = File('${directory.path}/api-token');
        final owner = File('${directory.path}/owner-token');
        final original = await api.readAsString();
        expect(original.trim().length, greaterThanOrEqualTo(40));
        expect(await owner.readAsString(), isNot(original));
        expect((await api.stat()).mode & 0x1ff, 0x1a0);
        await initializeCredentials(directory.path);
        expect(await api.readAsString(), original);
        await owner.writeAsString('');
        await expectLater(
          initializeCredentials(directory.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(await owner.readAsString(), '');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
