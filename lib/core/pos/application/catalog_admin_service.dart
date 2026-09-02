import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../domain/pricing_service.dart';
import '../pos_permissions.dart';

class CatalogAdminService {
  CatalogAdminService(this._db, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final String Function() _newId;

  Future<String> createCategory({
    required int workspaceId,
    required String name,
    int sortOrder = 0,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.catalog);
    final id = _newId();
    final now = DateTime.now();
    await _db
        .into(_db.localCategories)
        .insert(
          LocalCategoriesCompanion.insert(
            localId: id,
            workspaceId: workspaceId,
            name: name.trim(),
            sortOrder: Value(sortOrder),
            createdAt: Value(now),
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<String> createProduct({
    required int workspaceId,
    required String name,
    required double price,
    String? categoryLocalId,
    String? sku,
    String? barcode,
    double cost = 0,
    double taxRate = 0,
    int? stock,
    bool trackStock = false,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.catalog);
    final id = _newId();
    final now = DateTime.now();
    await _db
        .into(_db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            localId: id,
            workspaceId: workspaceId,
            categoryLocalId: Value(categoryLocalId),
            name: name.trim(),
            sku: Value(sku),
            barcode: Value(barcode),
            price: Value(Money.toCents(price)),
            cost: Value(Money.toCents(cost)),
            taxRate: Value(taxRate),
            stock: Value(stock),
            trackStock: Value(trackStock || stock != null),
            createdAt: Value(now),
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> updateProduct({
    required int workspaceId,
    required String localId,
    String? name,
    double? price,
    double? cost,
    String? sku,
    String? barcode,
    int? stock,
    bool? trackStock,
    bool? isActive,
    String? categoryLocalId,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.catalog);
    await (_db.update(_db.localProducts)..where(
          (t) => t.localId.equals(localId) & t.workspaceId.equals(workspaceId),
        ))
        .write(
          LocalProductsCompanion(
            name: name == null ? const Value.absent() : Value(name),
            price: price == null
                ? const Value.absent()
                : Value(Money.toCents(price)),
            cost: cost == null
                ? const Value.absent()
                : Value(Money.toCents(cost)),
            sku: sku == null ? const Value.absent() : Value(sku),
            barcode: barcode == null ? const Value.absent() : Value(barcode),
            stock: stock == null ? const Value.absent() : Value(stock),
            trackStock: trackStock == null
                ? const Value.absent()
                : Value(trackStock),
            isActive: isActive == null ? const Value.absent() : Value(isActive),
            categoryLocalId: categoryLocalId == null
                ? const Value.absent()
                : Value(categoryLocalId),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<Map<String, dynamic>?> findByBarcode({
    required int workspaceId,
    required String barcode,
  }) async {
    final q = barcode.trim();
    if (q.isEmpty) return null;
    final row =
        await (_db.select(_db.localProducts)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.isDeleted.equals(false) &
                  t.isActive.equals(true) &
                  (t.barcode.equals(q) | t.sku.equals(q)),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return {
      'id': row.localId,
      'local_id': row.localId,
      'name': row.name,
      'price': Money.fromCents(row.price),
      'barcode': row.barcode,
      'sku': row.sku,
      'stock': row.stock,
      'tax_rate': row.taxRate,
      'cost': Money.fromCents(row.cost),
    };
  }

  Future<void> deleteProduct({
    required int workspaceId,
    required String localId,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.catalog);
    await (_db.update(_db.localProducts)..where(
          (t) => t.localId.equals(localId) & t.workspaceId.equals(workspaceId),
        ))
        .write(
          LocalProductsCompanion(
            isDeleted: const Value(true),
            isActive: const Value(false),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<String> createTable({
    required int workspaceId,
    required String name,
    String? number,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.catalog);
    final localId = _newId();
    final now = DateTime.now();
    await _db
        .into(_db.localTables)
        .insert(
          LocalTablesCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            name: name.trim(),
            tableNumber: Value(number ?? name.trim()),
            status: const Value('available'),
            createdAt: Value(now),
            updatedAt: now,
          ),
        );
    return localId;
  }
}
