import 'dart:async';
import 'package:test/test.dart';
import 'package:tempod/src/services/shutdown.dart';

void main() {
  test('an unresponsive owner cannot prevent later cleanup attempts', () async {
    final stuck = Completer<void>();
    final cleaned = <String>[];
    final logs = <String>[];
    expect(
      await shutdownServices(
        {
          'http': () => stuck.future,
          'bluetooth': () async {
            cleaned.add('bluetooth');
          },
          'media': () async {
            cleaned.add('media');
          },
        },
        timeout: const Duration(milliseconds: 20),
        log: logs.add,
      ),
      isFalse,
    );
    expect(cleaned, ['bluetooth', 'media']);
    expect(logs, contains('shutdown: http incomplete (TimeoutException)'));
    stuck.completeError(StateError('late close failure'));
    await Future<void>.delayed(Duration.zero);
  });

  test('synchronous close failure does not skip remaining owners', () async {
    var closed = false;
    expect(
      await shutdownServices({
        'broken': () => throw StateError('close'),
        'remaining': () async {
          closed = true;
        },
      }, log: (_) {}),
      isFalse,
    );
    expect(closed, isTrue);
  });
}
