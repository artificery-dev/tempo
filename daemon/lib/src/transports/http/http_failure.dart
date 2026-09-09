final class HttpFailure implements Exception {
  const HttpFailure(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
}
