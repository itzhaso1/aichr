class AppConfig {
  static const appName = 'كاشير حاسم';
  static const apiVersion = 'cashier/v1';

  /// Override via --dart-define=CASHIER_API_BASE=https://example.com
  static const apiBase = String.fromEnvironment(
    'CASHIER_API_BASE',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static String get apiRoot => '$apiBase/api/$apiVersion';

  static const connectTimeout = Duration(seconds: 20);
  static const receiveTimeout = Duration(seconds: 30);

  static const menuPollSeconds = 5;
  static const tablesPollSeconds = 5;
  static const kitchenPollSeconds = 8;
}
