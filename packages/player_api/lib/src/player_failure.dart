/// A service failure that adapters can translate without exposing internals.
final class PlayerFailure implements Exception {
  const PlayerFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}
