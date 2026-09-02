import '../../local_db/app_database.dart';
import '../../local_db/workspace_scope.dart';
import '../../offline/offline_store.dart';
import '../../repositories/orders_repository.dart';
import '../pos_mode.dart';

/// One-shot Hive → Drift migration. POS daily paths must not read Hive after this.
class HiveLegacyMigration {
  HiveLegacyMigration(this._db, this._orders);

  final AppDatabase _db;
  final OrdersRepository _orders;

  static const metaKey = 'hive_pos_migrated';

  Future<void> runIfNeeded({
    required int workspaceId,
    required String deviceId,
  }) async {
    if (PosMode.isReservedStandaloneWorkspace(workspaceId)) return;
    final done = await _db.readMeta(workspaceId, metaKey);
    if (done == '1') return;
    await OfflineStore.instance.init();
    await _orders.migrateHivePending(
      workspaceId: workspaceId,
      deviceId: deviceId,
    );
    await _db.writeMeta(workspaceId, metaKey, '1', deviceId: deviceId);
  }
}
