import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Durable cashier device identity. Survives logout; bound to workspace at register/sync.
class DeviceIdentity {
  DeviceIdentity(this._storage);

  static const storageKey = 'cashier_device_id';

  final FlutterSecureStorage _storage;
  final _uuid = const Uuid();

  Future<String> getOrCreateDeviceId() async {
    final existing = await _storage.read(key: storageKey);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }
    final created = _uuid.v4();
    await _storage.write(key: storageKey, value: created);
    return created;
  }
}
