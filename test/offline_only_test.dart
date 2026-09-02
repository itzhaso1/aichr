import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/config/app_config.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';

void main() {
  test('offline-only build forces standalone runtime', () {
    expect(AppConfig.offlineOnly, isTrue);
    expect(
      PosMode.isStandaloneRuntime(isLocalMode: false, token: 'server-token'),
      isTrue,
    );
    expect(PosMode.admitRestoredSession('any-cloud-token'), isFalse);
  });
}
