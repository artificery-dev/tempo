/// tempod said no, in its own words.
class TempodError implements Exception {
  const TempodError(this.message);

  final String message;

  @override
  String toString() => 'tempod: $message';
}
