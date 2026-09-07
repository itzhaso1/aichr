import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../../local_db/workspace_scope.dart';
import '../../permissions/staff_permissions.dart';
import '../pos_errors.dart';
import '../pos_mode.dart';
import '../pos_permissions.dart';
import 'pin_hasher.dart';

class LocalAuthService {
  LocalAuthService(this._db, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final String Function() _newId;

  static const adminPermissions = StaffPermissions.adminDefaults;

  static Map<String, dynamic> permissionsFor(String role) =>
      StaffPermissions.defaultsForRole(role);

  static bool isKitchenRole(String? role) {
    final value = (role ?? '').trim().toLowerCase();
    return value == 'kitchen' || value == 'chef';
  }

  static String roleLabelAr(String? role) {
    final value = (role ?? '').trim().toLowerCase();
    return switch (value) {
      'admin' => 'مدير',
      'manager' => 'مشرف',
      'chef' || 'kitchen' => 'شيف',
      _ => 'كاشير',
    };
  }

  Future<LocalStore?> storeForWorkspace(int workspaceId) {
    return (_db.select(
      _db.localStores,
    )..where((t) => t.workspaceId.equals(workspaceId))).getSingleOrNull();
  }

  Future<LocalStore?> anyStore() {
    return (_db.select(_db.localStores)..limit(1)).getSingleOrNull();
  }

  Future<({LocalStore store, LocalUser user})> bootstrapStore({
    required String storeName,
    required String adminName,
    required String username,
    required String pin,
    String currency = 'SAR',
    double taxRate = 0,
  }) {
    if (pin.trim().length < 4) {
      throw const InvalidPin();
    }
    return _db.transaction(() async {
      final existing = await anyStore();
      if (existing != null) {
        throw const DatabaseFailure('المتجر المحلي موجود مسبقاً.');
      }
      final now = DateTime.now();
      final storeId = _newId();
      final userId = _newId();
      final salt = PinHasher.newSalt();
      await _db
          .into(_db.localStores)
          .insert(
            LocalStoresCompanion.insert(
              localId: storeId,
              workspaceId: PosMode.standaloneWorkspaceId,
              name: storeName.trim(),
              currency: Value(currency),
              taxRate: Value(taxRate),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _db
          .into(_db.localUsers)
          .insert(
            LocalUsersCompanion.insert(
              localId: userId,
              workspaceId: PosMode.standaloneWorkspaceId,
              name: adminName.trim(),
              username: username.trim().toLowerCase(),
              pinSalt: salt,
              pinHash: hashPin(pin, salt),
              role: const Value('admin'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _db.writeMeta(
        PosMode.standaloneWorkspaceId,
        'standalone_store_ready',
        '1',
      );
      final store = await storeForWorkspace(PosMode.standaloneWorkspaceId);
      final user = await (_db.select(
        _db.localUsers,
      )..where((t) => t.localId.equals(userId))).getSingle();
      return (store: store!, user: user);
    });
  }

  Future<LocalUser> login({
    required int workspaceId,
    required String username,
    required String pin,
  }) async {
    final email = username.trim().toLowerCase();
    final matches = await (_db.select(
      _db.localUsers,
    )..where((t) => t.workspaceId.equals(workspaceId))).get();
    LocalUser? user;
    for (final row in matches) {
      if (row.username.toLowerCase() == email) {
        user = row;
        break;
      }
    }
    if (user == null) throw const InvalidPin();
    if (!user.isActive) throw const UserInactive();
    if (!PinHasher.verify(pin, user.pinSalt, user.pinHash)) {
      throw const InvalidPin();
    }
    if (PinHasher.isLegacySha256(user.pinHash)) {
      await _upgradePinHash(user, pin);
      return (await (_db.select(
        _db.localUsers,
      )..where((t) => t.localId.equals(user!.localId))).getSingle());
    }
    return user;
  }

  Future<void> _upgradePinHash(LocalUser user, String pin) async {
    final salt = PinHasher.newSalt();
    await (_db.update(
      _db.localUsers,
    )..where((t) => t.localId.equals(user.localId))).write(
      LocalUsersCompanion(
        pinSalt: Value(salt),
        pinHash: Value(PinHasher.hash(pin, salt)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<List<LocalUser>> listUsers(int workspaceId) {
    return (_db.select(_db.localUsers)
          ..where((t) => t.workspaceId.equals(workspaceId))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
  }

  Future<String> createUser({
    required int workspaceId,
    required String name,
    required String username,
    required String pin,
    String role = 'cashier',
    Map<String, dynamic>? permissions,
    Map<String, dynamic>? actorPermissions,
  }) async {
    if (actorPermissions != null) {
      PosPermissions.require(actorPermissions, PosPermissions.users);
    }
    if (pin.trim().length < 4) throw const InvalidPin();
    final normalizedRole = switch (role.trim().toLowerCase()) {
      'chef' || 'kitchen' => 'chef',
      'admin' => 'admin',
      'manager' => 'manager',
      _ => 'cashier',
    };
    final email = username.trim().toLowerCase();
    if (email.isEmpty) {
      throw const DatabaseFailure('الإيميل مطلوب.');
    }
    final existing =
        await (_db.select(_db.localUsers)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.username.equals(email),
            ))
            .getSingleOrNull();
    if (existing != null) {
      throw const DatabaseFailure('الإيميل موجود مسبقاً.');
    }
    final id = _newId();
    final salt = PinHasher.newSalt();
    final now = DateTime.now();
    await _db
        .into(_db.localUsers)
        .insert(
          LocalUsersCompanion.insert(
            localId: id,
            workspaceId: workspaceId,
            name: name.trim(),
            username: email,
            pinSalt: salt,
            pinHash: hashPin(pin, salt),
            role: Value(normalizedRole),
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (permissions != null) {
      await writeUserAcl(
        workspaceId: workspaceId,
        userLocalId: id,
        permissions: permissions,
      );
    }
    return id;
  }

  static String aclKey(String userLocalId) => 'staff_acl.$userLocalId';

  Future<Map<String, dynamic>> readUserAcl({
    required int workspaceId,
    required String userLocalId,
  }) async {
    final row = await (_db.select(_db.localSettings)..where(
          (t) =>
              t.workspaceId.equals(workspaceId) &
              t.key.equals(aclKey(userLocalId)),
        ))
        .getSingleOrNull();
    if (row == null || row.valueJson.isEmpty) return const {};
    try {
      final decoded = jsonDecode(row.valueJson);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return const {};
  }

  Future<void> writeUserAcl({
    required int workspaceId,
    required String userLocalId,
    required Map<String, dynamic> permissions,
    Map<String, dynamic>? actorPermissions,
  }) async {
    if (actorPermissions != null) {
      PosPermissions.require(actorPermissions, PosPermissions.users);
    }
    await _db.into(_db.localSettings).insertOnConflictUpdate(
          LocalSettingsCompanion.insert(
            key: aclKey(userLocalId),
            workspaceId: workspaceId,
            valueJson: jsonEncode(permissions),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<Map<String, dynamic>> effectivePermissions(LocalUser user) async {
    final stored = await readUserAcl(
      workspaceId: user.workspaceId,
      userLocalId: user.localId,
    );
    return StaffPermissions.merge(role: user.role, stored: stored);
  }

  Future<void> updateUserPassword({
    required String userLocalId,
    required String pin,
  }) async {
    if (pin.trim().length < 4) throw const InvalidPin();
    final salt = PinHasher.newSalt();
    await (_db.update(
      _db.localUsers,
    )..where((t) => t.localId.equals(userLocalId))).write(
      LocalUsersCompanion(
        pinSalt: Value(salt),
        pinHash: Value(PinHasher.hash(pin, salt)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateStore({
    required String storeId,
    String? name,
    String? currency,
    double? taxRate,
    bool? allowNegativeStock,
    String? invoicePrefix,
    bool? connectedMode,
  }) async {
    await (_db.update(
      _db.localStores,
    )..where((t) => t.localId.equals(storeId))).write(
      LocalStoresCompanion(
        name: name == null ? const Value.absent() : Value(name),
        currency: currency == null ? const Value.absent() : Value(currency),
        taxRate: taxRate == null ? const Value.absent() : Value(taxRate),
        allowNegativeStock: allowNegativeStock == null
            ? const Value.absent()
            : Value(allowNegativeStock),
        invoicePrefix: invoicePrefix == null
            ? const Value.absent()
            : Value(invoicePrefix),
        connectedMode: connectedMode == null
            ? const Value.absent()
            : Value(connectedMode),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  static String hashPin(String pin, String salt) => PinHasher.hash(pin, salt);
}
