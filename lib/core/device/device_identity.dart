import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Durable cashier device identity. Survives logout; bound to workspace at register/sync.
class DeviceIdentity {
  DeviceIdentity(this._storage);

  static const storageKey = 'cashier_device_id';

  final FlutterSecureStorage _storage;
  final _uuid = const Uuid();
  String? _memoryId;

  Future<String> getOrCreateDeviceId() async {
    final memory = _memoryId;
    if (memory != null && memory.isNotEmpty) return memory;
    try {
      final existing = await _storage.read(key: storageKey);
      if (existing != null && existing.trim().isNotEmpty) {
        return _memoryId = existing.trim();
      }
      final created = _uuid.v4();
      await _storage.write(key: storageKey, value: created);
      return _memoryId = created;
    } catch (_) {
      // Plugin/storage unavailable (tests, locked keychain): still allow checkout.
      return _memoryId = _uuid.v4();
    }
  }
}
