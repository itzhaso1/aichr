import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/config/app_config.dart';

void main() {
  test('app config targets cashier API namespace', () {
    expect(AppConfig.appName, 'كاشير حاسم');
    expect(AppConfig.apiVersion, 'cashier/v1');
    expect(AppConfig.apiRoot.endsWith('/api/cashier/v1'), isTrue);
  });
}
