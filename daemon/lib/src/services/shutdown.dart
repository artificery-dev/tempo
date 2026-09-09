import 'dart:async';

/// Attempt every cleanup even when one peer or worker no longer answers.
/// A timeout bounds waiting; it does not pretend to cancel the underlying work.
Future<bool> shutdownServices(
  Map<String, Future<void> Function()> services, {
  Duration timeout = const Duration(seconds: 5),
  required void Function(String) log,
}) async {
  var complete = true;
  for (final entry in services.entries) {
    log('shutdown: ${entry.key} stopping');
    try {
      await Future<void>.sync(entry.value).timeout(timeout);
      log('shutdown: ${entry.key} stopped');
    } catch (error) {
      complete = false;
      log('shutdown: ${entry.key} incomplete (${error.runtimeType})');
    }
  }
  return complete;
}
