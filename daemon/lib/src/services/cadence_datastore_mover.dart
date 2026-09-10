import 'dart:io';

import 'package:daemon_client/daemon_client.dart' show DeviceSnapshot;
import 'package:tempo_data/tempo_data.dart';

import 'cadence_relocation.dart';

/// Device implementation of the storage selector's backend-owned move.
class CadenceDatastoreMover implements TempoDatastoreMover {
  CadenceDatastoreMover({
    required this.volume,
    required this.device,
    required this.user,
    required this.log,
    required this.event,
    this.executable = '/usr/local/lib/cadenced/bin/cadenced',
    this.run,
  });
  final Future<Map<String, Object?>> Function() volume;
  final DeviceSnapshot Function() device;
  final String user, executable;
  final void Function(String) log;
  final void Function(Map<String, Object?>) event;
  final Future<void> Function(CadenceRelocation)? run;

  @override
  Future<Map<String, Object?>> prepare({
    required String operationId,
    required String source,
    required String destination,
    required bool toCard,
  }) async {
    final reading = device();
    final state = await volume();
    if (state['state'] != 'attached' ||
        state['id'] is! String ||
        state['resolvedMediaRoot'] is! String ||
        state['storageKind'] != (toCard ? 'local' : 'portable')) {
      throw StateError('The active Cadence datastore cannot be moved');
    }
    if (reading.cardPath == null ||
        reading.cardMountId == null ||
        reading.cardSourceId == null) {
      throw StateError('An identified mounted SD card is required');
    }
    final cardStore = '${reading.cardPath}/.cadence';
    if ((toCard ? destination : source) != cardStore) {
      throw StateError('Datastore location does not match the mounted SD card');
    }
    final current = device();
    if (current.cardMountId != reading.cardMountId ||
        current.cardSourceId != reading.cardSourceId) {
      throw StateError('SD card changed while preparing the move');
    }
    return {
      ...CadenceRelocation(
        operationId: operationId,
        datastoreId: state['id'] as String,
        source: source,
        destination: destination,
        mediaRoot: state['resolvedMediaRoot'] as String,
      ).toJson(),
      'toCard': toCard,
      'cardPath': reading.cardPath,
      'cardSourceId': reading.cardSourceId,
    };
  }

  @override
  Future<void> execute(Map<String, Object?> intent) async {
    final reading = device();
    if (reading.cardPath != intent['cardPath'] ||
        reading.cardSourceId == null ||
        reading.cardSourceId != intent['cardSourceId'] ||
        reading.cardMountId == null) {
      throw StateError(
        'Reinsert the original SD card to finish the pending library move',
      );
    }
    // A reboot changes mount IDs; the stable physical CID binds consent to the
    // card, and the current kernel mount ID binds this execution to its mount.
    final toCard = intent['toCard'] as bool;
    final request = CadenceRelocation.fromJson({
      ...intent,
      'sourceMountId': toCard ? null : reading.cardMountId,
      'destinationMountId': toCard ? reading.cardMountId : null,
    });
    if ((toCard ? request.destination : request.source) !=
        '${reading.cardPath}/.cadence') {
      throw StateError('Pending datastore path differs from the intended card');
    }
    if (run case final execute?) {
      await execute(request);
      return;
    }
    final result = await Process.run('id', ['-g', user]);
    if (result.exitCode != 0) {
      throw StateError('Cannot identify Cadence account');
    }
    try {
      await request.run(
        user: user,
        gid: int.parse(result.stdout.toString().trim()),
        executable: executable,
        event: event,
        log: log,
      );
    } on CadenceRelocationFailure catch (error) {
      if (error.cancelSafe) {
        throw TempoDatastoreMoveRejected(
          'Library move was declined without changing either datastore: ${error.message}',
        );
      }
      rethrow;
    }
  }
}
