import 'package:flutter/foundation.dart';
import '../services/tempod.dart';

/// One request to the privileged daemon and its reply: the wire the state
/// below speaks over, and what a test hands in instead.
typedef DaemonRequest =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// Where first run stands on the machine, as the daemon reports it, and the
/// three things the setup asks the machine to do: put the clock right,
/// remember what was chosen for the next boot to apply, and restart.
///
/// Nothing here applies a choice itself. The account, its password, the
/// host name and the zone are all applied at boot, as root, before the
/// account has a process; the setup only writes them down (see
/// `platform/rootfs/tool/first_run.dart`).
class FirstRunState extends ChangeNotifier {
  FirstRunState({DaemonRequest? request})
    : _request = request ?? ((request) => Tempod().request(request));

  final DaemonRequest _request;

  /// Whether first run has finished on this machine.
  bool done = false;

  /// What has been applied already, by field: a flasher's configuration,
  /// or an earlier pass of this setup. Never a secret; `password` is a
  /// bool.
  Map<String, Object?> applied = const {};

  /// The last apply that failed, in the tool's words, or null.
  String? failure;

  /// Whether the daemon answered at all; off the device it will not.
  bool available = false;

  Future<void> load() async {
    try {
      final reply = await _request({'op': 'first-run'});
      done = reply['done'] == true;
      applied = (reply['applied'] as Map?)?.cast<String, Object?>() ?? const {};
      failure = reply['error'] as String?;
      available = true;
    } catch (error) {
      available = false;
      debugPrint('first run: the daemon did not answer: $error');
    }
    notifyListeners();
  }

  /// Whether a field is already settled and need not be asked for.
  bool has(String field) => field == 'password'
      ? applied['password'] == true
      : applied[field] != null;

  /// Whether the clock is trusted: synchronised over the network, or set.
  Future<ClockReading> clock() async {
    final reply = await _request({'op': 'clock'});
    return ClockReading(
      synchronized: reply['synchronized'] == true,
      ntp: reply['ntp'] == true,
      now: '${reply['now'] ?? ''}',
    );
  }

  /// Puts the clock right by hand, in local time.
  Future<void> setClock(DateTime when) async {
    String two(int n) => n.toString().padLeft(2, '0');
    final text =
        '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}:${two(when.second)}';
    await _request({'op': 'clock', 'set': text});
  }

  /// Writes the setup's choices down for the next boot. A password goes
  /// as typed; the daemon stores its hash and nothing else.
  Future<void> queue(Map<String, Object?> pending) async {
    await _request({'op': 'first-run', 'pending': pending});
  }

  Future<void> reboot() => _request({'op': 'reboot'});
}

class ClockReading {
  const ClockReading({
    required this.synchronized,
    required this.ntp,
    required this.now,
  });
  final bool synchronized, ntp;
  final String now;
}
