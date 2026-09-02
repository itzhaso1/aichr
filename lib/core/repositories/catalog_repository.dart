import 'dart:convert';

import 'package:drift/drift.dart';

import '../local_db/app_database.dart';
import '../pos/domain/pricing_service.dart';

/// Catalog reads come from Local DB (workspace-scoped). Network refresh is optional.
class CatalogRepository {
  CatalogRepository(this._db);

  final AppDatabase _db;

  Future<List<Map<String, dynamic>>> products(int workspaceId) async {
    if (workspaceId <= 0) return const [];
    final rows =
        await (_db.select(_db.localProducts)
              ..where(
                (t) =>
                    t.workspaceId.equals(workspaceId) &
                    t.isDeleted.equals(false),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.name)]))
            .get();
    return [
      for (final row in rows)
        {
          ..._safeMap(row.payloadJson),
          'id': row.serverId ?? row.localId,
          'local_id': row.localId,
          'name': row.name,
          'sku': row.sku,
          'barcode': row.barcode,
          'item_type': row.itemType,
          'price': Money.fromCents(row.price),
          'cost': Money.fromCents(row.cost),
          'tax_rate': row.taxRate,
          'stock': row.stock,
          'category_local_id': row.categoryLocalId,
          'is_active': row.isActive,
          'pos_item_category_id': row.categoryServerId,
          'workspace_id': row.workspaceId,
        },
    ];
  }

  Future<List<Map<String, dynamic>>> categories(int workspaceId) async {
    if (workspaceId <= 0) return const [];
    final rows =
        await (_db.select(_db.localCategories)
              ..where(
                (t) =>
                    t.workspaceId.equals(workspaceId) &
                    t.isDeleted.equals(false),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();
    return [
      for (final row in rows)
        {
          'id': row.serverId ?? row.localId,
          'local_id': row.localId,
          'name': row.name,
          'sort_order': row.sortOrder,
          'is_active': row.isActive,
          'workspace_id': row.workspaceId,
        },
    ];
  }

  Future<List<Map<String, dynamic>>> tables(int workspaceId) async {
    if (workspaceId <= 0) return const [];
    final rows =
        await (_db.select(_db.localTables)
              ..where((t) => t.workspaceId.equals(workspaceId))
              ..orderBy([(t) => OrderingTerm.asc(t.name)]))
            .get();
    return [
      for (final row in rows)
        {
          'id': row.serverId ?? row.localId,
          'local_id': row.localId,
          'name': row.name,
          'status': row.status,
          'capacity': row.capacity,
          'session_id': row.sessionServerId,
          'workspace_id': row.workspaceId,
          if (row.payloadJson.isNotEmpty) ..._safeMap(row.payloadJson),
        },
    ];
  }

  Map<String, dynamic> _safeMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded)
          ..removeWhere((key, value) => key == 'workspace_id' && value == null);
      }
    } catch (_) {}
    return const {};
  }
}
