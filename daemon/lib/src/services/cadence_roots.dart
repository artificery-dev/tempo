import 'package:cadence_client/cadence_client.dart';
import 'package:daemon_client/daemon_client.dart' show DeviceSnapshot;

/// Headless hardware-to-library coordination. No scanning or database ownership:
/// Cadence decides when work resumes after receiving the complete observation.
class CadenceRoots {
  CadenceRoots({
    required this.client,
    required this.device,
    this.cardMount = '/mnt/sd',
  });
  final CadenceClient client;
  final DeviceSnapshot Function() device;
  final String cardMount;
  final Map<String, String?> _suppressed = {};
  Future<void> _serial = Future.value();
  String? _lastSignature;
  bool _closed = false;

  Future<T> _queue<T>(Future<T> Function() action) {
    final next = _serial.then((_) {
      if (_closed) throw StateError('Cadence root bridge closed');
      return action();
    });
    _serial = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Called at startup and on hardware observations; cheap status polling also
  /// catches a daemon restart or newly configured roots while the UI is absent.
  Future<VolumeStatus> synchronize() => _queue(() => _synchronize());

  String _signature(VolumeStatus volume, DeviceSnapshot reading) =>
      '${volume.id}/${volume.generation}/${reading.cardPath}/${reading.cardMountId}/${reading.cardSourceId}/${_suppressed.keys.join(',')}';

  Future<VolumeStatus> _synchronize({
    bool force = false,
    String? expectedId,
    String? expectedGeneration,
  }) async {
    final reading = device();
    // A successful requested unmount yields null, not permission to reopen.
    // A genuinely new mount can release the old eject suppression.
    final blockedId = _suppressed[cardMount];
    if (_suppressed.containsKey(cardMount) &&
        reading.cardPath == cardMount &&
        reading.cardMountId != null &&
        reading.cardMountId != blockedId) {
      _suppressed.remove(cardMount);
    }
    final declaration = await client.volume();
    final status = VolumeStatus.fromJson(declaration);
    if ((expectedId != null && status.id != expectedId) ||
        (expectedGeneration != null &&
            status.generation != expectedGeneration)) {
      throw StateError('Library changed before the root availability update');
    }
    if (status.state != 'attached') {
      return status;
    }
    if (declaration['pathStyle'] != 'volume-posix') {
      throw const FormatException(
        'Tempo requires media-root-relative Cadence paths',
      );
    }
    final mediaMount = declaration['mediaMount'] as String?;
    if (!force &&
        status.rootAvailabilityReady &&
        _lastSignature == _signature(status, reading)) {
      return status;
    }
    final snapshot = await client.snapshot();
    final current = snapshot['volume'];
    if (current is! Map ||
        current['id'] != status.id ||
        current['generation'] != status.generation) {
      throw StateError('Library attachment changed while observing roots');
    }
    final roots = snapshot['roots'];
    if (roots is! List || status.id == null || status.generation == null) {
      throw const FormatException('Cadence root snapshot is incomplete');
    }
    final values = <RootAvailability>[];
    for (final root in roots) {
      if (root is! Map || root['id'] is! int || root['path'] is! String) {
        throw const FormatException('Cadence root snapshot is invalid');
      }
      final mount = root['mountPath'] as String?;
      if (mount != mediaMount) {
        throw const FormatException(
          'Library root mount differs from its declared media mount',
        );
      }
      final removable = mount != null;
      final available =
          !removable ||
          (!_suppressed.containsKey(mount) &&
              mount == reading.cardPath &&
              reading.cardMountId != null);
      values.add(
        RootAvailability(
          rootId: root['id'] as int,
          available: available,
          mountPath: mount,
          mountId: removable && available ? reading.cardMountId : null,
          sourceId: removable && available ? reading.cardSourceId : null,
        ),
      );
    }
    final result = await client.setRootAvailability(
      expectedId: status.id!,
      expectedGeneration: status.generation!,
      roots: values,
    );
    if (result.id != status.id || !result.rootAvailabilityReady) {
      throw StateError('Cadence did not accept root availability');
    }
    _lastSignature = _signature(result, reading);
    return result;
  }

  /// Releases card ownership before a normal hardware unmount. Internal
  /// metadata stays open; metadata on the card requires a full volume eject.
  /// Playback handles must already be closed by the frontend.
  Future<VolumeStatus> quiesceCard({
    String? expectedId,
    String? expectedGeneration,
  }) => _queue(() async {
    final reading = device();
    final declaration = await client.volume();
    final target = VolumeStatus.fromJson(declaration);
    if ((expectedId != null && target.id != expectedId) ||
        (expectedGeneration != null &&
            target.generation != expectedGeneration)) {
      throw StateError('Library attachment changed before releasing the card');
    }
    _suppressed.putIfAbsent(cardMount, () => reading.cardMountId);
    if (target.storageKind == 'portable') {
      if (target.id == null || target.generation == null) {
        throw StateError('Card datastore identity is unavailable');
      }
      final result = VolumeStatus.fromJson(
        await client.ejectVolume(
          expectedId: target.id,
          expectedGeneration: target.generation,
        ),
      );
      if (result.id != target.id ||
          result.generation != target.generation ||
          result.state != 'detached' ||
          !result.readyToUnmount) {
        throw StateError('Cadence has not released the card datastore');
      }
      return result;
    }
    final status = await _synchronize(
      force: true,
      expectedId: target.id,
      expectedGeneration: target.generation,
    );
    if (status.storageKind != 'local' ||
        (declaration['mediaMount'] != null &&
            !status.quiescentMountPaths.contains(cardMount))) {
      throw StateError('Cadence has not released every SD-card root');
    }
    return status;
  });

  /// Only an explicit resume or a new mount releases requested-eject suppression.
  Future<VolumeStatus> resumeCard() => _queue(() async {
    final status = await client.volumeStatus();
    if (status.storageKind == 'portable' && status.state != 'attached') {
      if (status.id == null || status.generation == null) {
        throw StateError('Card datastore identity is unavailable');
      }
      final attached = VolumeStatus.fromJson(
        await client.attachVolume(
          expectedId: status.id,
          expectedGeneration: status.generation,
        ),
      );
      if (attached.id != status.id || attached.state != 'attached') {
        throw StateError('Cadence could not reopen the card datastore');
      }
    }
    _suppressed.remove(cardMount);
    return _synchronize(force: true);
  });

  Future<void> close() async {
    _closed = true;
    await _serial;
  }
}
