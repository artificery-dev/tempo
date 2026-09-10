/// Portable volume status. Activity describes Cadence work, not kernel or
/// player I/O. Only the host's successful OS unmount permits physical removal.
class VolumeStatus {
  VolumeStatus.fromJson(Map<String, Object?> json)
    : id = json['id'] as String?,
      generation = json['generation'] as String?,
      state = json['state'] as String,
      storageKind = json['storageKind'] as String,
      rootAvailabilityReady = json['rootAvailabilityReady'] as bool,
      quiescentRootIds = (json['quiescentRootIds'] as List).cast<int>(),
      quiescentMountPaths = (json['quiescentMountPaths'] as List)
          .cast<String>(),
      readyToUnmount = json['readyToUnmount'] as bool,
      activity = (json['activity'] as Map).cast<String, Object?>(),
      error = json['error'] as String?;
  final String? id, generation, error;
  final String state, storageKind;
  final bool rootAvailabilityReady;
  final List<int> quiescentRootIds;
  final List<String> quiescentMountPaths;
  final bool readyToUnmount;
  final Map<String, Object?> activity;
}

/// A local playback path supplied by the host adapter. Valid only for the
/// returned attachment generation. Discard on quiescing/removal/reconnect,
/// and release all player handles before requesting Cadence eject.
class MediaLocation {
  MediaLocation.fromJson(Map<String, Object?> json)
    : libraryUuid = json['libraryUuid'] as String,
      itemId = json['itemId'] as int,
      volumeId = json['volumeId'] as String,
      generation = json['generation'] as String,
      path = json['path'] as String;
  final String libraryUuid, volumeId, generation, path;
  final int itemId;
}

/// Availability supplied by the host hardware bridge, never inferred by UI
/// directory existence. For available removable roots, use the current mount ID.
class RootAvailability {
  const RootAvailability({
    required this.rootId,
    required this.available,
    this.mountPath,
    this.mountId,
    this.sourceId,
  });
  final int rootId;
  final bool available;
  final String? mountPath, mountId;

  /// Stable host-observed media identity, such as an SD CID. A changed or
  /// unknown source forces full identity revalidation; mountId alone is not
  /// stable across reattachment or daemon restart.
  final String? sourceId;
  Map<String, Object?> toJson() => {
    'rootId': rootId,
    'available': available,
    if (mountPath != null) 'mountPath': mountPath,
    if (mountId != null) 'mountId': mountId,
    if (sourceId != null) 'sourceId': sourceId,
  };
}
