import 'dart:async';
import 'dart:convert';

import 'package:player_api/player_api.dart';
import 'package:relic/relic.dart';
import 'package:web_socket/web_socket.dart';

/// At most one unacknowledged snapshot and one coalesced replacement per
/// client. This bounds application output even when a peer stops reading.
final class EventClient {
  EventClient({
    required this.player,
    required this.socket,
    required this.ackTimeout,
    required this.maxMessageBytes,
    required this.onClosed,
  });
  final PlayerService player;
  final Duration ackTimeout;
  final int maxMessageBytes;
  final void Function(EventClient) onClosed;
  final RelicWebSocket socket;
  StreamSubscription<PlayerSnapshot>? _states;
  StreamSubscription<WebSocketEvent>? _incoming;
  Timer? _deadline;
  PlayerSnapshot? _pending;
  int? _awaiting;
  int _sent = -1;
  Future<void>? _closing;

  void start() {
    socket.pingInterval = const Duration(seconds: 10);
    _incoming = socket.events.listen(
      _receive,
      onError: (Object error) => unawaited(close(4002, 'Connection failed')),
      onDone: () => unawaited(close()),
    );
    _states = player.changes.listen(
      _offer,
      onError: (Object error) =>
          unawaited(close(4004, 'Player service failed')),
    );
    _offer(player.snapshot);
  }

  void _offer(PlayerSnapshot state) {
    if (_closing != null || state.revision <= _sent) return;
    if (_awaiting != null) {
      if (_pending == null || state.revision > _pending!.revision) {
        _pending = state;
      }
      return;
    }
    final text = jsonEncode({'type': 'snapshot', 'state': state.toJson()});
    if (utf8.encode(text).length > maxMessageBytes) {
      unawaited(close(4009, 'Snapshot too large'));
      return;
    }
    _sent = state.revision;
    _awaiting = state.revision;
    if (!socket.trySendText(text)) {
      unawaited(close());
      return;
    }
    _deadline = Timer(ackTimeout, () {
      unawaited(close(4008, 'Snapshot acknowledgement timed out'));
    });
  }

  void _receive(WebSocketEvent event) {
    if (_closing != null) return;
    switch (event) {
      case TextDataReceived(:final text):
        try {
          if (utf8.encode(text).length > maxMessageBytes) {
            unawaited(close(4009, 'Message too large'));
            return;
          }
          final data = jsonDecode(text);
          if (data is! Map<String, dynamic> ||
              data.length != 2 ||
              data['type'] != 'ack' ||
              data['revision'] is! int ||
              data['revision'] < 0 ||
              data['revision'] > _sent) {
            throw const FormatException('Expected snapshot acknowledgement.');
          }
          if (data['revision'] == _awaiting) {
            _deadline?.cancel();
            _awaiting = null;
            final pending = _pending;
            _pending = null;
            if (pending != null) _offer(pending);
          }
        } on FormatException {
          unawaited(close(4002, 'Invalid acknowledgement'));
        }
      case BinaryDataReceived():
        unawaited(close(4002, 'Use JSON text messages'));
      case CloseReceived():
        unawaited(close());
    }
  }

  Future<void> close([int code = 1000, String reason = 'Closed']) =>
      _closing ??= _close(code, reason);
  Future<void> _close(int code, String reason) async {
    _deadline?.cancel();
    _pending = null;
    onClosed(this);
    await _states?.cancel();
    await _incoming?.cancel();
    await socket.tryClose(code, reason);
  }
}
