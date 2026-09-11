import 'dart:async';
import 'package:daemon_client/daemon_client.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:flutter/foundation.dart';

class DaemonCardMaintenance extends ValueNotifier<CardMaintenanceStatus>
    implements CardMaintenanceController {
  DaemonCardMaintenance({
    required this.client,
    required this.cadence,
    required this.device,
    required this.stopPlayback,
  }) : super(const CardMaintenanceStatus()) {
    _changes = device.changes.listen((reading) {
      if (value.phase == CardMaintenancePhase.ejected &&
          reading.cardMountId != null &&
          reading.cardMountId != _target?.cardMountId) {
        _target = null;
        _datastoreId = null;
        unawaited(_run('resume'));
      }
    });
  }
  final StorageClient client;
  final CadenceLibrary cadence;
  final DeviceClient device;
  final Future<void> Function() stopPlayback;
  DeviceSnapshot? _target;
  String? _datastoreId;
  bool _closed = false;
  late final StreamSubscription<DeviceSnapshot> _changes;

  Future<void> _run(String action) async {
    if (_closed || value.busy) return;
    value = CardMaintenanceStatus(
      phase: switch (action) {
        'eject' => CardMaintenancePhase.ejecting,
        'format' => CardMaintenancePhase.formatting,
        _ => CardMaintenancePhase.resuming,
      },
    );
    try {
      final volume = await cadence.refresh();
      final reading = device.snapshot;
      if (_target == null &&
          (reading.cardMountId == null || reading.cardSourceId == null)) {
        throw StateError('Insert an SD card before ejecting it');
      }
      _target ??= reading;
      _datastoreId ??= volume.id;
      final target = _target!;
      if (_datastoreId == null ||
          volume.generation == null ||
          volume.id != _datastoreId ||
          target.cardMountId == null ||
          target.cardSourceId == null) {
        throw StateError('An identified SD card and library are required');
      }
      cadence.blockPlayback();
      await stopPlayback();
      final result = await client.cardMaintenance(
        action: action,
        datastoreId: _datastoreId!,
        generation: volume.generation!,
        mountId: target.cardMountId!,
        cardId: target.cardSourceId!,
      );
      if (result['state'] !=
          (action == 'eject'
              ? 'ejected'
              : action == 'format'
              ? 'formatted'
              : 'resumed')) {
        throw StateError('Card maintenance was not acknowledged');
      }
      if (action != 'eject') {
        await cadence.resumeAfterHostMaintenance(_datastoreId!);
        _target = null;
        _datastoreId = null;
      }
      if (!_closed) {
        value = CardMaintenanceStatus(
          phase: action == 'eject'
              ? CardMaintenancePhase.ejected
              : action == 'format'
              ? CardMaintenancePhase.formatted
              : CardMaintenancePhase.idle,
        );
      }
    } catch (error) {
      if (!_closed) {
        value = CardMaintenanceStatus(
          phase: CardMaintenancePhase.failed,
          error: '$error',
        );
      }
    }
  }

  @override
  Future<void> eject() => _run('eject');
  @override
  Future<void> resume() => _run('resume');
  @override
  Future<void> format() => _run('format');
  @override
  void dispose() {
    _closed = true;
    unawaited(_changes.cancel());
    super.dispose();
  }
}
