import 'playback_readiness_gate.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:player_api/player_api.dart';

/// Publishes an existing playback owner to tempod and reconnects after loss.
/// No commands are replayed across connections. Playback stays in [player].
final class PlaybackOwnerConnection {
  PlaybackOwnerConnection({
    required this.uri,
    required this.token,
    required this.player,
    void Function(bool)? onBluetoothPlaybackReady,
    this.retryDelay = const Duration(seconds: 2),
  }) : _readiness = PlaybackReadinessGate(
         player.snapshot,
         onBluetoothPlaybackReady,
       ),
       sessionId = List.generate(
         16,
         (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
       ).join();
  final PlaybackReadinessGate _readiness;
  StreamSubscription<PlayerSnapshot>? _changes;
  final Uri uri;
  final String token;
  final PlayerService player;
  final String sessionId;
  final Duration retryDelay;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _incoming;
  Timer? _retry;
  bool _closed = false;
  bool _started = false;
  bool _busy = false;
  Future<void>? _connecting;

  void start() {
    if (_closed || _started) return;
    _started = true;
    _changes = player.changes.listen((state) {
      final transitioned = _readiness.update(state);
      final socket = _socket;
      // Preserve even a pause/resume completed between periodic sync polls.
      // Position-only changes continue to use the bounded polling transport.
      if (transitioned && socket != null) {
        try {
          _send(
            socket,
            PlayerSnapshotEmitted(sessionId: sessionId, state: state),
          );
        } catch (_) {
          _lost(socket);
        }
      }
    });
    _connect();
  }

  void _connect() {
    if (_closed || _connecting != null) return;
    _connecting = _open().whenComplete(() => _connecting = null);
  }

  Future<void> _open() async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: {'authorization': 'Bearer $token'},
        customClient: http,
      ).timeout(const Duration(seconds: 5));
      if (_closed) {
        await socket.close();
        return;
      }
      socket.pingInterval = const Duration(seconds: 10);
      _socket = socket;
      _readiness.update(player.snapshot);
      _readiness.connected();
      _incoming = socket.listen(
        (message) => _receive(socket, message),
        onError: (Object _) => _lost(socket),
        onDone: () => _lost(socket),
      );
      _send(
        socket,
        PlayerSnapshotEmitted(sessionId: sessionId, state: player.snapshot),
      );
    } catch (_) {
      final socket = _socket;
      if (socket != null) _lost(socket);
      _scheduleRetry();
    } finally {
      http.close(force: true);
    }
  }

  void _scheduleRetry() {
    if (!_closed) {
      _retry ??= Timer(retryDelay, () {
        _retry = null;
        _connect();
      });
    }
  }

  void _lost(WebSocket socket) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    _readiness.disconnected();
    unawaited(_incoming?.cancel());
    unawaited(socket.close());
    _scheduleRetry();
  }

  void _send(WebSocket socket, PlayerEvent event) {
    if (_closed || !identical(socket, _socket)) return;
    final text = jsonEncode(event.toJson());
    if (utf8.encode(text).length > 65536) {
      throw const FormatException('Owner event too large');
    }
    socket.add(text);
  }

  Future<void> _receive(WebSocket socket, dynamic message) async {
    if (_closed || !identical(socket, _socket)) return;
    try {
      if (message is! String || utf8.encode(message).length > 65536) {
        throw const FormatException('Invalid owner request');
      }
      final event = PlayerEvent.fromJson(jsonDecode(message));
      if (event.sessionId != sessionId) {
        throw const FormatException('Wrong owner session');
      }
      if (event is BluetoothPlaybackReady) {
        _readiness.update(player.snapshot);
        _readiness.receive(event);
      } else if (event is PlayerSyncRequested) {
        _send(
          socket,
          PlayerSnapshotEmitted(sessionId: sessionId, state: player.snapshot),
        );
      } else if (event is PlayerCommandRequested) {
        if (_busy) {
          _send(
            socket,
            PlayerCommandFailed(
              sessionId: sessionId,
              requestId: event.requestId,
              failure: const PlayerFailure(
                'player_busy',
                'A command is still running.',
              ),
            ),
          );
          return;
        }
        _busy = true;
        try {
          final state = await player.execute(event.command);
          _send(
            socket,
            PlayerCommandSucceeded(
              sessionId: sessionId,
              requestId: event.requestId,
              state: state,
            ),
          );
        } on PlayerFailure catch (error) {
          _send(
            socket,
            PlayerCommandFailed(
              sessionId: sessionId,
              requestId: event.requestId,
              failure: error,
            ),
          );
        } catch (_) {
          _send(
            socket,
            PlayerCommandFailed(
              sessionId: sessionId,
              requestId: event.requestId,
              failure: const PlayerFailure(
                'command_failed',
                'Playback operation failed.',
              ),
            ),
          );
        } finally {
          _busy = false;
        }
      } else {
        throw const FormatException('Unexpected event');
      }
    } catch (_) {
      _lost(socket);
    }
  }

  Future<void> close() async {
    _closed = true;
    _readiness.disconnected();
    await _changes?.cancel();
    _retry?.cancel();
    await _incoming?.cancel();
    await _socket?.close();
    _socket = null;
    await _connecting;
  }
}
