import 'package:drift/drift.dart';

import '../local_db/app_database.dart';
import '../pos/domain/pricing_service.dart';
import '../local_db/local_ids.dart';
import '../local_db/workspace_scope.dart';

/// Seeds a minimal local catalog/tables so POS works without a Laravel account.
class LocalDemoSeedService {
  LocalDemoSeedService(this._db);

  final AppDatabase _db;

  static const demoWorkspaceId = 1;

  Future<void> ensureDemoWorkspace({
    int workspaceId = demoWorkspaceId,
    String deviceId = 'local-device',
  }) async {
    if (workspaceId <= 0) return;
    final products = await _db.productCount(workspaceId);
    if (products == 0) {
      await _seedCatalog(workspaceId);
    }
    final tables = await (_db.select(_db.localTables)
          ..where((t) => t.workspaceId.equals(workspaceId)))
        .get();
    if (tables.isEmpty) {
      await _seedTables(workspaceId);
    }
    await _db.markInitialSyncCompleted(workspaceId, deviceId: deviceId);
  }

  Future<void> _seedCatalog(int workspaceId) async {
    final now = DateTime.now();
    await _db.into(_db.localCategories).insertOnConflictUpdate(
          LocalCategoriesCompanion.insert(
            localId: LocalIds.category(workspaceId, 1),
            workspaceId: workspaceId,
            serverId: const Value(1),
            name: 'مشروبات',
            updatedAt: now,
          ),
        );
    await _db.into(_db.localCategories).insertOnConflictUpdate(
          LocalCategoriesCompanion.insert(
            localId: LocalIds.category(workspaceId, 2),
            workspaceId: workspaceId,
            serverId: const Value(2),
            name: 'أكلات',
            updatedAt: now,
          ),
        );
    final items = <(int, int, String, double)>[
      (1, 1, 'شاي', 5),
      (2, 1, 'قهوة', 8),
      (3, 1, 'عصير برتقال', 12),
      (4, 2, 'برجر', 25),
      (5, 2, 'بطاطس', 10),
      (6, 2, 'سلطة', 15),
    ];
    for (final item in items) {
      await _db.into(_db.localProducts).insertOnConflictUpdate(
            LocalProductsCompanion.insert(
              localId: LocalIds.product(workspaceId, item.$1),
              workspaceId: workspaceId,
              serverId: Value(item.$1),
              categoryServerId: Value(item.$2),
              categoryLocalId: Value(LocalIds.category(workspaceId, item.$2)),
              name: item.$3,
              price: Value(Money.toCents(item.$4)),
              isActive: const Value(true),
              isDeleted: const Value(false),
              updatedAt: now,
              payloadJson: Value(
                '{"id":${item.$1},"name":"${item.$3}","price":${item.$4},"pos_item_category_id":${item.$2}}',
              ),
            ),
          );
    }
  }

  Future<void> _seedTables(int workspaceId) async {
    final now = DateTime.now();
    for (var i = 1; i <= 8; i++) {
      await _db.into(_db.localTables).insertOnConflictUpdate(
            LocalTablesCompanion.insert(
              localId: LocalIds.table(workspaceId, i),
              workspaceId: workspaceId,
              serverId: Value(i),
              name: 'طاولة $i',
              status: const Value('available'),
              capacity: Value(4),
              payloadJson: Value(
                '{"id":$i,"name":"طاولة $i","status":"available","capacity":4}',
              ),
              updatedAt: now,
            ),
          );
    }
  }
}
