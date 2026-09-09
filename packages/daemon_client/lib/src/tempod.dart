import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tempod_error.dart';

/// The frontend's end of tempod's control socket.
///
/// tempod is the privileged half of the player (docs/app/daemon.md): the
/// UI asks, it does. The wire is as small as a wire gets - connect, one
/// JSON object on one line, one JSON object back, and the daemon hangs up -
/// so this is a function with a socket path, not a client library. Every
/// reply carries `ok`; a false one becomes a [TempodError] with the
/// daemon's own words in it.
class Tempod {
  Tempod({String? socket})
    : socket = socket ?? Platform.environment['TEMPOD_SOCKET'] ?? defaultSocket;

  /// Where the daemon listens: `daemon.socket` in config.yaml, which the
  /// rootfs build and tempod's own defaults are read from too. A desktop
  /// running a development tempod points `TEMPOD_SOCKET` elsewhere.
  static const defaultSocket = '/run/tempod/tempod.sock';

  final String socket;

  /// Long enough for the slowest op: the vendor FM seek timeout is fifteen
  /// seconds, and the reply comes only after the receiver finishes.
  static const timeout = Duration(seconds: 20);

  /// Whether there is a daemon to reach at all: its socket exists. A
  /// desktop, and a test, have none, and the services that would chatter
  /// at it (feedback on every word, the output poll) stay quiet instead of
  /// failing on schedule.
  bool get available => File(socket).existsSync();

  /// One request, one reply. Throws a [SocketException] when there is no
  /// daemon to talk to - a desktop, or a device whose tempod is down - and
  /// a [TempodError] when it answered no.
  Future<Map<String, Object?>> request(Map<String, Object?> request) async {
    final connection = await Socket.connect(
      InternetAddress(socket, type: InternetAddressType.unix),
      0,
    ).timeout(timeout);
    try {
      connection.add(utf8.encode('${jsonEncode(request)}\n'));
      await connection.flush();
      // The daemon closes after its line, so the stream's end is the reply's.
      final bytes = await connection
          .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
          .timeout(timeout);
      final reply = jsonDecode(utf8.decode(bytes).trim());
      if (reply is! Map<String, Object?>) {
        throw TempodError('reply is not an object: $reply');
      }
      if (reply['ok'] != true) {
        throw TempodError(reply['error']?.toString() ?? 'refused');
      }
      return reply;
    } finally {
      connection.destroy();
    }
  }
}
