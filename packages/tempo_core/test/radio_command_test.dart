import 'package:tempod/src/services/host_radios.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/src/services/radios.dart';

void main() {
  test('CLI failure responses fail even when exit status is zero', () async {
    await expectLater(
      runRadioCommand('printf', ['FAIL\n']),
      throwsA(isA<RadioFailure>()),
    );
    await expectLater(
      runRadioCommand('printf', [
        'Failed to connect: org.bluez.Error.Failed\n',
      ]),
      throwsA(isA<RadioFailure>()),
    );
    expect(await runRadioCommand('printf', ['OK\n']), 'OK');
  });

  test('escaped UTF-8 SSIDs and backslashes decode without shell parsing', () {
    expect(HostRadios.decodeSsid(r'Caf\xc3\xa9'), 'Café');
    expect(HostRadios.decodeSsid(r'Home\\Office'), r'Home\Office');
    expect(HostRadios.decodeSsid(r'$(touch nope)'), r'$(touch nope)');
  });
}
