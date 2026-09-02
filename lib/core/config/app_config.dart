class AppConfig {
  static const appName = 'كاشير حاسم';
  static const apiVersion = 'cashier/v1';

  /// Hard offline build: no Laravel API, no sync, no connectivity checks.
  /// Network login / Google / remote bootstrap are disabled for the whole app.
  static const bool offlineOnly = true;

  /// Kept for compile compatibility only — never used while [offlineOnly] is true.
  /// Override via --dart-define=CASHIER_API_BASE=https://example.com
  static const apiBase = String.fromEnvironment(
    'CASHIER_API_BASE',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static String get apiRoot => '$apiBase/api/$apiVersion';

  static const connectTimeout = Duration(seconds: 20);
  static const receiveTimeout = Duration(seconds: 30);

  /// Local refresh intervals (SQLite / UI). Not network polling to a server.
  static const menuPollSeconds = 5;
  static const tablesPollSeconds = 5;
  static const kitchenPollSeconds = 8;
}
