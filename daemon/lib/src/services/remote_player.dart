import 'dart:async';

import 'package:player_api/player_api.dart';

/// A proxy for the single Flutter playback owner. It never plays or queues audio.
final class RemotePlayer implements PlayerService {
  RemotePlayer({this.commandTimeout = const Duration(seconds: 10)});
  final Duration commandTimeout;
  final _changes = StreamController<PlayerSnapshot>.broadcast(sync: true);
  PlayerSnapshot _state = const PlayerSnapshot(revision: 0, available: false);
  String? _session;
  void Function(PlayerEvent)? _send;
  Completer<PlayerSnapshot>? _pending;
  String? _requestId;
  int _sequence = 0;
  int _ownerRevision = -1;
  bool _closed = false;

  @override
  PlayerSnapshot get snapshot => _state;
  @override
  Stream<PlayerSnapshot> get changes => _changes.stream;
  String? get sessionId => _session;

  void attach(PlayerSnapshotEmitted initial, void Function(PlayerEvent) send) {
    if (_closed || _send != null) {
      throw StateError('Playback owner already attached.');
    }
    _session = initial.sessionId;
    _send = send;
    _ownerRevision = -1;
    _adopt(initial.state);
  }

  void receive(PlayerEvent event) {
    if (_closed || _send == null || event.sessionId != _session) return;
    if (event is PlayerSnapshotEmitted) {
      _adopt(event.state);
    } else if (event is PlayerCommandSucceeded &&
        event.requestId == _requestId) {
      _adopt(event.state);
      _pending?.complete(_state);
      _pending = null;
      _requestId = null;
    } else if (event is PlayerCommandFailed && event.requestId == _requestId) {
      _pending?.completeError(event.failure);
      _pending = null;
      _requestId = null;
    } else {
      throw const FormatException('Unexpected owner event.');
    }
  }

  void _adopt(PlayerSnapshot state) {
    if (state.revision <= _ownerRevision) return;
    _ownerRevision = state.revision;
    _publish(state);
  }

  void _publish(PlayerSnapshot state) {
    _state = PlayerSnapshot(
      revision: _state.revision + 1,
      available: state.available,
      status: state.status,
      trackId: state.trackId,
      title: state.title,
      artist: state.artist,
      album: state.album,
      hasNext: state.hasNext,
      positionMs: state.positionMs,
      durationMs: state.durationMs,
      volume: state.volume,
    );
    _changes.add(_state);
  }

  /// Private daemon-to-owner notification; never accepted as a public command.
  void notifyBluetoothPlaybackReady(bool active) {
    final session = _session;
    if (session == null || _closed) return;
    try {
      _send?.call(
        BluetoothPlaybackReady(
          sessionId: session,
          stateRevision: _ownerRevision,
          active: active,
        ),
      );
    } catch (_) {
      detach();
    }
  }

  @override
  Future<PlayerSnapshot> execute(PlayerCommand command) async {
    final send = _send;
    if (send == null || !_state.available || _closed) {
      throw const PlayerFailure(
        'player_unavailable',
        'No player is connected.',
      );
    }
    if (_pending != null) {
      throw const PlayerFailure(
        'player_busy',
        'A player command is still running.',
      );
    }
    final pending = Completer<PlayerSnapshot>();
    _pending = pending;
    final id = _requestId = '${++_sequence}';
    final result = pending.future.timeout(
      commandTimeout,
      onTimeout: () {
        // Keep the slot occupied until a reply or disconnect: outcome is unknown.
        throw const PlayerFailure(
          'command_timeout',
          'Player command outcome is unknown.',
        );
      },
    );
    try {
      send(
        PlayerCommandRequested(
          sessionId: _session!,
          requestId: id,
          command: command,
        ),
      );
    } catch (_) {
      detach();
    }
    return result;
  }

  void detach() {
    if (_send == null) return;
    _send = null;
    _session = null;
    _pending?.completeError(
      const PlayerFailure(
        'player_unavailable',
        'Player disconnected; command outcome may be unknown.',
      ),
    );
    _pending = null;
    _requestId = null;
    if (!_closed) _publish(const PlayerSnapshot(revision: 0, available: false));
  }

  Future<void> close() async {
    detach();
    _closed = true;
    await _changes.close();
  }
}
