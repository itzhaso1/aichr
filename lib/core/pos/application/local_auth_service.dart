import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../../local_db/workspace_scope.dart';
import '../pos_errors.dart';
import '../pos_mode.dart';
import 'pin_hasher.dart';

class LocalAuthService {
  LocalAuthService(this._db, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final String Function() _newId;

  static const adminPermissions = {
    'pos.use': true,
    'pos.manage': true,
    'orders.create': true,
    'orders.manage': true,
    'orders.discount': true,
    'orders.refund': true,
    'tables.manage': true,
    'menu.manage': true,
    'reports.view': true,
    'shifts.open': true,
    'shifts.close': true,
    'shifts.manage': true,
    'cash.movement': true,
    'stock.adjust': true,
    'workspace.manage': true,
  };

  static Map<String, dynamic> permissionsFor(String role) {
    switch (role) {
      case 'admin':
        return Map<String, dynamic>.from(adminPermissions);
      case 'manager':
        return {
          ...adminPermissions,
          'workspace.manage': false,
          'pos.manage': false,
        };
      case 'kitchen':
        return {'pos.use': true, 'orders.manage': true, 'tables.manage': true};
      default:
        return {
          'pos.use': true,
          'orders.create': true,
          'shifts.open': true,
          'reports.view': true,
        };
    }
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
    final user =
        await (_db.select(_db.localUsers)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.username.equals(username.trim().toLowerCase()),
            ))
            .getSingleOrNull();
    if (user == null) throw const InvalidPin();
    if (!user.isActive) throw const UserInactive();
    if (!PinHasher.verify(pin, user.pinSalt, user.pinHash)) {
      throw const InvalidPin();
    }
    if (PinHasher.isLegacySha256(user.pinHash)) {
      await _upgradePinHash(user, pin);
      return (await (_db.select(
        _db.localUsers,
      )..where((t) => t.localId.equals(user.localId))).getSingle());
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
  }) async {
    if (pin.trim().length < 4) throw const InvalidPin();
    final existing =
        await (_db.select(_db.localUsers)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.username.equals(username.trim().toLowerCase()),
            ))
            .getSingleOrNull();
    if (existing != null) {
      throw const DatabaseFailure('اسم المستخدم موجود مسبقاً.');
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
            username: username.trim().toLowerCase(),
            pinSalt: salt,
            pinHash: hashPin(pin, salt),
            role: Value(role),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
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
