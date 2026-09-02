/// Process-wide counter of attempted HTTP calls.
///
/// Standalone POS core tests assert this stays at 0. The Dio interceptor
/// increments it before any request is sent or rejected.
class NetworkGuard {
  NetworkGuard._();

  static int attempts = 0;

  static void recordAttempt() => attempts++;

  static void reset() => attempts = 0;
}
