import 'dart:async';
import 'dart:convert';

import 'package:player_api/player_api.dart';
import 'package:relic/relic.dart';
import 'package:web_socket/web_socket.dart';

import '../../services/remote_player.dart';

/// One authenticated owner connection. Pulling snapshots bounds delivery to one
/// outstanding sync request; observers still subscribe to the proxy's changes.
final class OwnerConnection {
  OwnerConnection({
    required this.player,
    required this.socket,
    required this.onClosed,
    this.syncInterval = const Duration(seconds: 1),
  });
  final RemotePlayer player;
  final RelicWebSocket socket;
  final void Function() onClosed;
  final Duration syncInterval;
  StreamSubscription<WebSocketEvent>? _incoming;
  Timer? _deadline;
  Timer? _sync;
  bool _attached = false;
  Future<void>? _closing;

  void start() {
    socket.pingInterval = const Duration(seconds: 10);
    _armDeadline();
    _incoming = socket.events.listen(
      _receive,
      onError: (Object _) => unawaited(close()),
      onDone: () => unawaited(close()),
    );
  }

  void _armDeadline() {
    _deadline?.cancel();
    _deadline = Timer(const Duration(seconds: 5), () => unawaited(close()));
  }

  void _send(PlayerEvent event) {
    final text = jsonEncode(event.toJson());
    if (utf8.encode(text).length > 65536 || !socket.trySendText(text)) {
      unawaited(close());
      throw StateError('Owner send failed.');
    }
  }

  void _receive(WebSocketEvent message) {
    if (_closing != null) return;
    if (message is! TextDataReceived) {
      unawaited(close());
      return;
    }
    try {
      if (utf8.encode(message.text).length > 65536) {
        throw const FormatException('Message too large');
      }
      final event = PlayerEvent.fromJson(jsonDecode(message.text));
      if (!_attached) {
        if (event is! PlayerSnapshotEmitted) {
          throw const FormatException('Expected initial snapshot');
        }
        player.attach(event, _send);
        _attached = true;
      } else {
        if (event.sessionId != player.sessionId) {
          throw const FormatException('Stale owner session');
        }
        player.receive(event);
      }
      if (event is PlayerSnapshotEmitted) {
        _deadline?.cancel();
        _sync?.cancel();
        _sync = Timer(syncInterval, () {
          if (_closing != null) return;
          try {
            _send(PlayerSyncRequested(sessionId: player.sessionId!));
            _armDeadline();
          } catch (_) {
            unawaited(close());
          }
        });
      }
    } catch (_) {
      unawaited(close());
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _deadline?.cancel();
    _sync?.cancel();
    if (_attached) player.detach();
    await _incoming?.cancel();
    await socket.tryClose(4003, 'Owner connection closed');
    onClosed();
  }
}
