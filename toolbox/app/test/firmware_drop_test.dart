import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/firmware_drop.dart';

void main() {
  test('a single package repeated by a desktop remains one selection', () {
    expect(
      firmwareDropPaths([
        '/home/me/Tempo firmware.y2-firmware',
        'file:///home/me/Tempo%20firmware.y2-firmware',
        '/home/me/Tempo firmware.y2-firmware\u0000',
        '',
      ]),
      ['/home/me/Tempo firmware.y2-firmware'],
    );
  });
  test('recovers a raw URI list without accepting comments or portal keys', () {
    expect(
      firmwareDropPaths(
        [],
        rawText: '# comment\r\nfile:///tmp/Tempo.y2-firmware\r\n',
      ),
      ['/tmp/Tempo.y2-firmware'],
    );
    expect(firmwareDropPaths([], rawText: 'portal-transfer-key'), isEmpty);
  });
  test('keeps two distinct packages distinct', () {
    expect(firmwareDropPaths(['/tmp/a.zip', '/tmp/b.zip']), hasLength(2));
  });
  test('normalizes Windows file URIs and preserves resolved portal paths', () {
    expect(
      firmwareDropPaths([r'C:\ROM\tempo.zip', 'file:///C:/ROM/tempo.zip']),
      [r'C:\ROM\tempo.zip'],
    );
    expect(
      firmwareDropPaths([
        '/run/user/1000/doc/abc/tempo.zip',
      ], rawText: 'file:///home/me/tempo.zip'),
      ['/run/user/1000/doc/abc/tempo.zip'],
    );
  });
}
