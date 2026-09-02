import '../api/cashier_api.dart';

/// Registers the durable Secure Storage device_id with Laravel (idempotent).
class DeviceRegistrationService {
  DeviceRegistrationService(this._api);

  final CashierApiClient _api;

  Future<Map<String, dynamic>> register({
    required String deviceId,
    String name = 'كاشير حاسم',
    String platform = 'cashier',
  }) {
    return _api.post(
      '/devices/register',
      data: {
        'device_id': deviceId,
        'name': name,
        'platform': platform,
      },
    );
  }
}
