import 'dart:async';

import 'package:cadence_client/cadence_client.dart';

/// Tempo's attachment boundary. Paths are obtained from Cadence, never composed
/// from the card mountpoint or persisted across attachment generations.
class CadenceLibrary {
  CadenceLibrary(this.client);
  final CadenceClient client;
  VolumeStatus? _volume;
  int _revision = 0;
  bool _blocked = false;
  bool _closed = false;
  bool _maintaining = false;
  VolumeStatus? _ejectTarget;
  StreamSubscription<Map<String, Object?>>? _events;

  final _changes = StreamController<VolumeStatus?>.broadcast(sync: true);
  Stream<VolumeStatus?> get changes => _changes.stream;
  VolumeStatus? get volume => _volume;

  /// Cadence's contribution to the card-use indicator. The UI must also count
  /// playback and kernel I/O; this is never a safe-to-remove signal.
  bool get cadenceBusy {
    final status = _volume;
    if (status == null || _maintaining) return true;
    if (status.state == 'detached') return false;
    if (status.state != 'attached') return true;
    final activity = status.activity;
    for (final key in [
      'activeReadRequests',
      'activeWriteRequests',
      'runningJobs',
      'queuedJobs',
    ]) {
      final count = activity[key];
      if (count is! num || count != 0) return true;
    }
    if (activity['draining'] != false) return true;
    final artwork = activity['artwork'];
    return artwork is! Map ||
        artwork['running'] != false ||
        artwork['pending'] != 0;
  }

  void _publish(VolumeStatus? status) {
    final previous = _volume;
    if (previous?.id != status?.id ||
        previous?.generation != status?.generation ||
        previous?.state != status?.state) {
      _revision++;
    }
    _volume = status;
    if (!_closed) _changes.add(status);
  }

  bool get canResolve => !_closed && !_blocked && _volume?.state == 'attached';

  /// Reconnection requires an authoritative status read before resolving paths.
  Future<void> connect() async {
    if (_closed) throw StateError('Cadence library closed');
    await _events?.cancel();
    invalidate();
    _events = client.events.listen(
      (event) {
        final type = event['type'];
        if (type != 'volume-state-changed' && type != 'volume-activity') return;
        if (type == 'volume-state-changed') invalidate();
        try {
          // These events already contain a full status. Fetching /snapshot here
          // would generate more activity and keep the indicator busy itself.
          final status = VolumeStatus.fromJson(event);
          if (_volume != null &&
              (_volume!.id != status.id ||
                  _volume!.generation != status.generation)) {
            invalidate();
          }
          _publish(status);
        } catch (_) {
          invalidate();
        }
      },
      onError: (Object _) => invalidate(),
      onDone: invalidate,
    );
    await refresh();
  }

  void invalidate() {
    _revision++;
    _publish(null);
  }

  /// Caller sets this before stopping playback for eject. A failed eject stays
  /// blocked until the user explicitly resumes; idle polling cannot reopen it.
  void blockPlayback() {
    _blocked = true;
    invalidate();
  }

  Future<VolumeStatus> refresh() async {
    if (_closed) throw StateError('Cadence library closed');
    final revision = _revision;
    late final VolumeStatus status;
    try {
      status = await client.volumeStatus();
    } catch (_) {
      invalidate();
      rethrow;
    }
    if (_closed || revision != _revision) {
      throw StateError('Library attachment changed while reading status');
    }
    _publish(status);
    return status;
  }

  Future<MediaLocation> resolve(String libraryUuid, int itemId) async {
    if (_closed || _blocked) throw StateError('Library playback is blocked');
    final status = await refresh();
    final revision = _revision;
    if (status.state != 'attached' ||
        status.id == null ||
        status.generation == null) {
      throw StateError('Library volume is unavailable');
    }
    final location = await client.resolveMedia(
      libraryUuid: libraryUuid,
      itemId: itemId,
      volumeId: status.id!,
      generation: status.generation!,
    );
    // Reject completions from before eject, disconnect, or a card swap.
    if (_closed ||
        _blocked ||
        revision != _revision ||
        location.volumeId != status.id ||
        location.generation != status.generation ||
        location.libraryUuid != libraryUuid ||
        location.itemId != itemId) {
      throw StateError('Library attachment changed while resolving media');
    }
    return location;
  }

  /// Coordinated eject. The callbacks are Tempo-owned: stopPlayback must
  /// release decoder handles; unmount must report real OS success or throw.
  Future<void> eject({
    required Future<void> Function() stopPlayback,
    required Future<void> Function() unmount,
  }) async {
    if (_closed || _maintaining) {
      throw StateError('Library operation in progress');
    }
    _maintaining = true;
    try {
      final target = _ejectTarget ?? await refresh();
      if (target.id == null || target.generation == null) {
        throw StateError('Library attachment identity unavailable');
      }
      _ejectTarget = target;
      blockPlayback();
      await stopPlayback();
      final detached = VolumeStatus.fromJson(
        await client.ejectVolume(
          expectedId: target.id,
          expectedGeneration: target.generation,
        ),
      );
      if (!detached.readyToUnmount ||
          detached.state != 'detached' ||
          detached.id != target.id ||
          detached.generation != target.generation) {
        throw StateError(
          detached.error ?? 'Cadence did not finish releasing the library',
        );
      }
      _publish(detached);
      await unmount();
    } finally {
      _maintaining = false;
      _publish(_volume);
    }
  }

  /// Explicitly resume after a failed/cancelled eject while still mounted.
  /// Never silently attach a different card from a stale retry dialog.
  Future<void> resume() async {
    if (_closed || _maintaining) {
      throw StateError('Library operation in progress');
    }
    final target = _ejectTarget;
    if (target == null) throw StateError('No library attachment to resume');
    _maintaining = true;
    try {
      await client.attachVolume(
        expectedId: target.id,
        expectedGeneration: target.generation,
      );
      final status = await refresh();
      if (status.state != 'attached' || status.id != target.id) {
        throw StateError('Library did not reattach');
      }
      _blocked = false;
      _ejectTarget = null;
    } finally {
      _maintaining = false;
      _publish(_volume);
    }
  }

  /// The hardware bridge has resumed roots/metadata and completed its handshake.
  /// Only release the UI playback gate for the originally selected datastore.
  Future<void> resumeAfterHostMaintenance(String expectedId) async {
    final status = await refresh();
    if (status.id != expectedId || status.state != 'attached') {
      throw StateError('The original library has not resumed');
    }
    _blocked = false;
    _ejectTarget = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    invalidate();
    await _events?.cancel();
    await _changes.close();
    // The owner closes the shared client after its other consumers stop.
  }
}
