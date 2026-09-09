import 'tempod.dart';

/// Applies changes in order, so rapid selections cannot race in the daemon.
class DeviceTimeZone {
  DeviceTimeZone({Tempod? tempod}) : _tempod = tempod ?? Tempod();
  final Tempod _tempod;
  Future<void> _pending = Future.value();

  Future<void> setZone(String zone) {
    final next = _pending.then((_) async {
      final reply = await _tempod.request({'op': 'timezone', 'zone': zone});
      if (reply['zone'] != zone) {
        throw const TempodError('time zone was not applied');
      }
    });
    // A failed request must not stop later selections from being applied.
    _pending = next.catchError((Object _) {});
    return next;
  }
}
