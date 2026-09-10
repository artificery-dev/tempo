import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef RelocationProcess = Future<Process> Function(List<String> arguments);

class CadenceRelocationFailure extends StateError {
  CadenceRelocationFailure(super.message, {required this.cancelSafe});
  final bool cancelSafe;
}

/// The supervisor persists this identity before stopping any datastore owners.
/// Retrying must reuse it: Cadence may already have retired the source.
class CadenceRelocation {
  CadenceRelocation({
    required this.operationId,
    required this.datastoreId,
    required this.source,
    required this.destination,
    required this.mediaRoot,
    this.sourceMountId,
    this.destinationMountId,
  });
  final String operationId, datastoreId, source, destination, mediaRoot;
  final String? sourceMountId, destinationMountId;

  List<String> get arguments => [
    'relocate',
    '--source',
    source,
    '--source-kind',
    sourceMountId == null ? 'directory' : 'mount',
    if (sourceMountId != null) ...['--source-mount-id', sourceMountId!],
    '--destination',
    destination,
    '--destination-kind',
    destinationMountId == null ? 'directory' : 'mount',
    if (destinationMountId != null) ...[
      '--destination-mount-id',
      destinationMountId!,
    ],
    '--operation-id',
    operationId,
    '--expected-id',
    datastoreId,
  ];

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'datastoreId': datastoreId,
    'source': source,
    'destination': destination,
    'mediaRoot': mediaRoot,
    'sourceMountId': sourceMountId,
    'destinationMountId': destinationMountId,
  };

  factory CadenceRelocation.fromJson(Map<String, Object?> value) =>
      CadenceRelocation(
        operationId: value['operationId'] as String,
        datastoreId: value['datastoreId'] as String,
        source: value['source'] as String,
        destination: value['destination'] as String,
        mediaRoot: value['mediaRoot'] as String,
        sourceMountId: value['sourceMountId'] as String?,
        destinationMountId: value['destinationMountId'] as String?,
      );

  /// Invoke only with the UI and cadenced stopped. Cadence's exclusive leases
  /// also reject an accidental concurrent owner. This launcher never copies or
  /// interprets database files and never falls back to opening the source.
  Future<Map<String, Object?>> run({
    required String user,
    required int gid,
    required void Function(Map<String, Object?>) event,
    required void Function(String) log,
    String executable = '/usr/local/lib/cadenced/bin/cadenced',
    RelocationProcess? start,
  }) async {
    final process =
        await (start ??
            (arguments) => Process.start('setpriv', [
              '--reuid=$user',
              '--regid=$gid',
              '--init-groups',
              executable,
              ...arguments,
            ]))(arguments);
    Map<String, Object?>? complete;
    Object? protocolError;
    String? failure;
    bool cancelSafe = false;
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final value = Map<String, Object?>.from(jsonDecode(line) as Map);
              if (value['operationId'] != operationId ||
                  complete != null ||
                  failure != null) {
                throw const FormatException(
                  'Unexpected relocation identity or trailing event',
                );
              }
              switch (value['event']) {
                case 'relocation-progress':
                  break;
                case 'relocation-error':
                  failure = '${value['error']}';
                  cancelSafe =
                      value['cancelSafe'] == true &&
                      value['retryWithSameOperationId'] == false;
                case 'relocation-complete':
                  if (value['state'] != 'done' ||
                      value['datastoreId'] != datastoreId ||
                      value['store'] != destination ||
                      value['storageKind'] !=
                          (destinationMountId == null ? 'local' : 'portable') ||
                      value['resolvedMediaRoot'] != mediaRoot ||
                      value['sourceRetired'] != true ||
                      value['sourceRetained'] != true ||
                      value['libraries'] is! List) {
                    throw const FormatException(
                      'Relocation acknowledgement does not match the requested move',
                    );
                  }
                  complete = value;
                default:
                  throw const FormatException('Unknown relocation event');
              }
              event(value);
            } catch (error) {
              protocolError ??= error;
            }
          },
          onError: (Object error) {
            protocolError ??= error;
          },
        );
    final errors = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          log,
          onError: (Object error) {
            protocolError ??= error;
          },
        );
    // No arbitrary timeout: a large cache can take time. EOF or an "activated"
    // progress event is insufficient; wait for both closed streams and exit 0.
    final drained =
        Future.wait([
          output.asFuture<void>(),
          errors.asFuture<void>(),
        ]).then<void>(
          (_) {},
          onError: (Object error) {
            protocolError ??= error;
          },
        );
    final code = await process.exitCode;
    await drained;
    if (code != 0 ||
        protocolError != null ||
        failure != null ||
        complete == null) {
      final safe =
          code == 75 && protocolError == null && failure != null && cancelSafe;
      throw CadenceRelocationFailure(
        'Cadence relocation was not acknowledged (exit $code): '
        '${protocolError ?? failure ?? 'missing completion'}. '
        '${safe ? 'Cadence confirmed the source remains active.' : 'Keep operation $operationId pending and retry it before opening a datastore.'}',
        cancelSafe: safe,
      );
    }
    return complete!;
  }
}
