import 'dart:async';
import 'package:test/test.dart';
import 'package:tempod/src/services/service_notify.dart';

void main() {
  test(
    'profile startup extends immediately and stops before readiness',
    () async {
      final messages = <String>[];
      final deadline = ProfileStartupDeadline(
        budget: const Duration(milliseconds: 150),
        interval: const Duration(milliseconds: 5),
        notify: messages.add,
      )..start();
      expect(messages, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      deadline.close();
      final count = messages.length;
      expect(count, greaterThan(1));
      final remaining = messages
          .map((m) => int.parse(m.split('=').last))
          .toList();
      expect(remaining.first, lessThanOrEqualTo(150000));
      expect(remaining.last, lessThan(remaining.first));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(messages, hasLength(count));
    },
  );
  test(
    'failure cleanup cancels extension and exhausted budget never renews',
    () async {
      final messages = <String>[];
      final deadline = ProfileStartupDeadline(
        budget: const Duration(milliseconds: 10),
        interval: const Duration(milliseconds: 3),
        notify: messages.add,
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(messages.last, 'EXTEND_TIMEOUT_USEC=1');
      final count = messages.length;
      try {
        throw StateError('migration failed');
      } catch (_) {
        deadline.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(messages, hasLength(count));
    },
  );
}
