/// Profile location is separate from the media folders scanned by the player.
final class StorageStatus {
  const StorageStatus({
    required this.policy,
    required this.location,
    required this.available,
    required this.mediaHome,
    this.dataPath,
    this.configPath,
    required this.sdAvailable,
    required this.needsPrompt,
    required this.restartPending,
    required this.deviceProfileExists,
    required this.sdProfileExists,
    this.error,
  });
  final String policy, location, mediaHome;
  final String? dataPath, configPath, error;
  final bool available,
      sdAvailable,
      needsPrompt,
      restartPending,
      deviceProfileExists,
      sdProfileExists;

  factory StorageStatus.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !const ['yes', 'no', 'ask'].contains(value['policy']) ||
        !const ['device', 'sd'].contains(value['location']) ||
        value['mediaHome'] is! String ||
        const [
          'available',
          'sdAvailable',
          'needsPrompt',
          'restartPending',
          'deviceProfileExists',
          'sdProfileExists',
        ].any((key) => value[key] is! bool) ||
        const [
          'dataPath',
          'configPath',
          'error',
        ].any((key) => value[key] != null && value[key] is! String) ||
        (value['available'] == true &&
            (value['dataPath'] == null || value['configPath'] == null))) {
      throw const FormatException('Invalid storage status.');
    }
    return StorageStatus(
      policy: value['policy'] as String,
      location: value['location'] as String,
      available: value['available'] as bool,
      mediaHome: value['mediaHome'] as String,
      dataPath: value['dataPath'] as String?,
      configPath: value['configPath'] as String?,
      error: value['error'] as String?,
      sdAvailable: value['sdAvailable'] as bool,
      needsPrompt: value['needsPrompt'] as bool,
      restartPending: value['restartPending'] as bool,
      deviceProfileExists: value['deviceProfileExists'] as bool,
      sdProfileExists: value['sdProfileExists'] as bool,
    );
  }
  Map<String, Object?> toJson() => {
    'policy': policy,
    'location': location,
    'available': available,
    'mediaHome': mediaHome,
    'dataPath': dataPath,
    'configPath': configPath,
    'sdAvailable': sdAvailable,
    'needsPrompt': needsPrompt,
    'restartPending': restartPending,
    'deviceProfileExists': deviceProfileExists,
    'sdProfileExists': sdProfileExists,
    'error': error,
  };
}

final class StorageSelection {
  const StorageSelection({
    required this.policy,
    this.adoptExisting = false,
    this.replaceExisting = false,
  });
  final String policy;
  final bool adoptExisting, replaceExisting;
  factory StorageSelection.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) => !const [
            'policy',
            'adoptExisting',
            'replaceExisting',
          ].contains(key),
        ) ||
        !const ['yes', 'no', 'ask'].contains(value['policy']) ||
        (value['adoptExisting'] != null && value['adoptExisting'] is! bool) ||
        (value['replaceExisting'] != null &&
            value['replaceExisting'] is! bool) ||
        (value['adoptExisting'] == true && value['replaceExisting'] == true)) {
      throw const FormatException('Invalid storage selection.');
    }
    return StorageSelection(
      policy: value['policy'] as String,
      adoptExisting: value['adoptExisting'] == true,
      replaceExisting: value['replaceExisting'] == true,
    );
  }
  Map<String, Object?> toJson() => {
    'policy': policy,
    'adoptExisting': adoptExisting,
    'replaceExisting': replaceExisting,
  };
}
