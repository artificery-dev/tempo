import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/emulator/src/card_import.dart';

void main() {
  test(
    'mobile documents become persistent media without overwriting files',
    () async {
      final card = await Directory.systemTemp.createTemp('tempo-card-import-');
      addTearDown(() => card.delete(recursive: true));
      XFile file(String name, int byte) =>
          XFile.fromData(Uint8List.fromList([byte]), path: name);
      expect(
        await importCardFiles([
          file('track.mp3', 1),
          file('track.mp3', 2),
          file('../clip.mp4', 3),
        ], card),
        3,
      );
      expect(await File('${card.path}/Music/track.mp3').readAsBytes(), [1]);
      expect(await File('${card.path}/Music/track (1).mp3').readAsBytes(), [2]);
      expect(await File('${card.path}/Movies/clip.mp4').readAsBytes(), [3]);
    },
  );
}
