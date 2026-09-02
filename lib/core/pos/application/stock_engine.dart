import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../pos_errors.dart';
import '../pos_permissions.dart';

class StockEngine {
  StockEngine(this._db, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final String Function() _newId;

  /// Atomic stock change. Must be called inside an existing transaction.
  Future<void> apply({
    required int workspaceId,
    required String productLocalId,
    required String type,
    required int quantity,
    required bool allowNegative,
    String? referenceType,
    String? referenceId,
    String? userId,
    String? deviceId,
    Map<String, dynamic>? permissions,
  }) async {
    if (quantity <= 0) {
      throw const InvalidDiscount();
    }
    if (type == 'adjustment' || type == 'manual' || type == 'damage') {
      PosPermissions.require(permissions, PosPermissions.stockAdjust);
    }
    final product =
        await (_db.select(_db.localProducts)..where(
              (t) =>
                  t.localId.equals(productLocalId) &
                  t.workspaceId.equals(workspaceId),
            ))
            .getSingleOrNull();
    if (product == null) {
      throw const DatabaseFailure('الصنف غير موجود محلياً.');
    }
    if (!product.trackStock && product.stock == null) {
      return;
    }
    final before = product.stock ?? 0;
    final after = switch (type) {
      'sale' || 'damage' => before - quantity,
      'return' || 'purchase' || 'opening' || 'manual' => before + quantity,
      'adjustment' => quantity,
      _ => before - quantity,
    };
    if (!allowNegative && after < 0) {
      throw InsufficientStock(product.name);
    }
    await (_db.update(
      _db.localProducts,
    )..where((t) => t.localId.equals(productLocalId))).write(
      LocalProductsCompanion(
        stock: Value(after),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _db
        .into(_db.localStockMovements)
        .insert(
          LocalStockMovementsCompanion.insert(
            localId: _newId(),
            workspaceId: workspaceId,
            deviceId: deviceId ?? 'local',
            productLocalId: Value(productLocalId),
            productServerId: Value(product.serverId),
            kind: type,
            quantity: type == 'adjustment' ? (after - before).abs() : quantity,
            beforeQuantity: Value(before),
            afterQuantity: Value(after),
            referenceType: Value(referenceType),
            referenceId: Value(referenceId),
            userId: Value(userId),
            syncStatus: const Value('local'),
            clientReference: _newId(),
            createdAt: DateTime.now(),
          ),
        );
  }
}
