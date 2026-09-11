import 'dart:io';

import 'package:cadence_client/cadence_client.dart';
import 'package:daemon_client/daemon_client.dart' show DeviceSnapshot;
import 'cadence_roots.dart';

/// Authenticated card maintenance. The UI stops decoders before requesting
/// eject; normal unmount also refuses any handles that remain open elsewhere.
class CardHost {
  CardHost({
    required this.client,
    required this.roots,
    required this.device,
    required this.refreshDevice,
    this.unmount = _unmount,
    this.format = _format,
  });
  final CadenceClient client;
  final CadenceRoots roots;
  final DeviceSnapshot Function() device;
  final Future<void> Function() refreshDevice;
  final Future<void> Function(String mountId) unmount;
  final Future<void> Function(String cardId) format;
  bool _busy = false;
  String? _ejected;

  static Future<void> _format(String id) async {
    final result = await Process.run(
      '/usr/local/lib/tempo-system/tempo-system',
      ['format-sd', id],
    );
    if (result.exitCode != 0) throw StateError(result.stderr.toString().trim());
  }

  static Future<void> _unmount(String id) async {
    final result = await Process.run(
      '/usr/local/lib/tempo-system/tempo-system',
      ['eject-sd', id],
    );
    if (result.exitCode != 0) throw StateError(result.stderr.toString().trim());
  }

  Future<Map<String, Object?>> execute(Object? value) async {
    if (_busy) throw StateError('A card operation is already running');
    const fields = {'action', 'datastoreId', 'generation', 'mountId', 'cardId'};
    if (value is! Map ||
        value.length != fields.length ||
        value.keys.any((key) => !fields.contains(key)) ||
        value.values.any((v) => v is! String || v.isEmpty) ||
        !['eject', 'resume', 'format'].contains(value['action'])) {
      throw const FormatException('Invalid card maintenance request');
    }
    final action = value['action'] as String;
    final mount = value['mountId'] as String;
    final card = value['cardId'] as String;
    final id = value['datastoreId'] as String;
    final generation = value['generation'] as String;
    final identity = '$card/$mount/$id';
    _busy = true;
    try {
      await refreshDevice();
      var reading = device();
      if (action == 'eject' &&
          reading.cardPath == null &&
          _ejected == identity) {
        return {'state': 'ejected'};
      }
      void checkCard() {
        reading = device();
        if (reading.cardPath != '/mnt/sd' ||
            reading.cardMountId != mount ||
            reading.cardSourceId != card) {
          throw StateError('The selected SD card is no longer mounted');
        }
      }

      checkCard();
      final current = await client.volumeStatus();
      if (current.id != id || current.generation != generation) {
        throw StateError('Library changed before card maintenance');
      }
      if (action == 'resume') {
        await roots.resumeCard();
        _ejected = null;
        return {'state': 'resumed'};
      }
      if (action == 'format' && current.storageKind != 'local') {
        throw StateError('Move library data to Internal before formatting');
      }
      await roots.quiesceCard(expectedId: id, expectedGeneration: generation);
      await refreshDevice();
      checkCard();
      if (action == 'format') {
        await format(card);
        await refreshDevice();
        await roots.resumeCard();
        _ejected = null;
        return {'state': 'formatted'};
      }
      await unmount(mount);
      _ejected = identity;
      await refreshDevice();
      return {'state': 'ejected'};
    } finally {
      _busy = false;
    }
  }
}
