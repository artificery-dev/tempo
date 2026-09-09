import 'package:player_api/player_api.dart';

/// Rejects delayed AVRCP readiness from an earlier playback transition.
final class PlaybackReadinessGate {
  PlaybackReadinessGate(this._state, this.notify)
    : _transitionRevision = _state.revision;
  final void Function(bool)? notify;
  PlayerSnapshot _state;
  int _transitionRevision;
  bool _connected = false;
  void connected() {
    _connected = true;
    _transitionRevision = _state.revision;
    notify?.call(false);
  }

  void disconnected() {
    _connected = false;
    notify?.call(false);
  }

  bool update(PlayerSnapshot state) {
    final transitioned =
        state.status != _state.status || state.available != _state.available;
    if (transitioned) {
      _transitionRevision = state.revision;
      // Also gate a new resume until its BlueZ notification has settled.
      notify?.call(false);
    }
    _state = state;
    return transitioned;
  }

  void receive(BluetoothPlaybackReady event) {
    if (!_connected ||
        event.stateRevision < _transitionRevision ||
        event.stateRevision > _state.revision) {
      return;
    }
    if (!event.active ||
        (_state.available && _state.status == PlaybackStatus.playing)) {
      notify?.call(event.active);
    }
  }
}
