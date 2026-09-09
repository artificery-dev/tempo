import 'playback_status.dart';

/// A complete state snapshot. Revisions increase within one service session.
/// A new event connection always starts with a complete snapshot; revisions
/// from different daemon sessions must not be compared.
final class PlayerSnapshot {
  const PlayerSnapshot({
    required this.revision,
    required this.available,
    this.status = PlaybackStatus.stopped,
    this.trackId,
    this.title,
    this.artist,
    this.album,
    this.hasNext = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.volume = 1,
  });

  factory PlayerSnapshot.fromJson(Object? input) {
    if (input is! Map<String, dynamic>) {
      throw const FormatException('State must be an object.');
    }
    final revision = input['revision'];
    final available = input['available'];
    final position = input['positionMs'];
    final duration = input['durationMs'];
    final volume = input['volume'];
    final status = PlaybackStatus.values.where(
      (s) => s.name == input['status'],
    );
    if (revision is! int ||
        revision < 0 ||
        available is! bool ||
        position is! int ||
        position < 0 ||
        duration is! int ||
        duration < 0 ||
        volume is! num ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 1 ||
        status.isEmpty ||
        (input['trackId'] != null && input['trackId'] is! String) ||
        (input['title'] != null && input['title'] is! String) ||
        (input['artist'] != null && input['artist'] is! String) ||
        (input['album'] != null && input['album'] is! String) ||
        (input['hasNext'] != null && input['hasNext'] is! bool)) {
      throw const FormatException('Invalid player state fields.');
    }
    return PlayerSnapshot(
      revision: revision,
      available: available,
      status: status.single,
      trackId: input['trackId'] as String?,
      title: input['title'] as String?,
      artist: input['artist'] as String?,
      album: input['album'] as String?,
      hasNext: input['hasNext'] as bool? ?? false,
      positionMs: position,
      durationMs: duration,
      volume: volume.toDouble(),
    );
  }

  final int revision;
  final bool available;
  final PlaybackStatus status;
  final String? trackId;
  final String? title;
  final String? artist;
  final String? album;
  final bool hasNext;
  final int positionMs;
  final int durationMs;
  final double volume;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'available': available,
    'status': status.name,
    'trackId': trackId,
    'title': title,
    'artist': artist,
    'album': album,
    'hasNext': hasNext,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'volume': volume,
  };
}
