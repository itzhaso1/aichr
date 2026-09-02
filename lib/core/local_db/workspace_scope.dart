import 'package:drift/drift.dart';

import 'app_database.dart';

/// Fail-closed workspace scope for every local POS query/write.
class WorkspaceScope {
  const WorkspaceScope(
    this.workspaceId, {
    this.deviceId,
    this.accountId,
    this.userId,
  });

  final int workspaceId;
  final String? deviceId;
  final int? accountId;
  final int? userId;

  void assertValid() {
    if (workspaceId <= 0) {
      throw StateError('workspace_id is required for local POS access');
    }
  }
}

extension WorkspaceScopedDb on AppDatabase {
  Future<bool> hasInitialSync(int workspaceId) async {
    final row =
        await (select(syncMetadata)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.key.equals(SyncMetaKeys.initialSyncCompleted),
            ))
            .getSingleOrNull();
    return row?.value == '1';
  }

  Future<void> markInitialSyncCompleted(
    int workspaceId, {
    String? deviceId,
  }) async {
    await into(syncMetadata).insertOnConflictUpdate(
      SyncMetadataCompanion.insert(
        key: SyncMetaKeys.initialSyncCompleted,
        workspaceId: workspaceId,
        deviceId: Value(deviceId),
        value: '1',
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<String?> readCursor(int workspaceId) async {
    final row =
        await (select(syncMetadata)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.key.equals(SyncMetaKeys.syncCursor),
            ))
            .getSingleOrNull();
    return row?.value;
  }

  Future<void> writeCursor(
    int workspaceId,
    String cursor, {
    String? deviceId,
  }) async {
    await writeMeta(
      workspaceId,
      SyncMetaKeys.syncCursor,
      cursor,
      deviceId: deviceId,
    );
  }

  Future<void> writeMeta(
    int workspaceId,
    String key,
    String value, {
    String? deviceId,
  }) async {
    await into(syncMetadata).insertOnConflictUpdate(
      SyncMetadataCompanion.insert(
        key: key,
        workspaceId: workspaceId,
        deviceId: Value(deviceId),
        value: value,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<String?> readMeta(int workspaceId, String key) async {
    final row =
        await (select(syncMetadata)..where(
              (t) => t.workspaceId.equals(workspaceId) & t.key.equals(key),
            ))
            .getSingleOrNull();
    return row?.value;
  }

  Future<DateTime?> readMetaTime(int workspaceId, String key) async {
    final raw = await readMeta(workspaceId, key);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<int> productCount(int workspaceId) async {
    final count = countAll();
    final query = selectOnly(localProducts)
      ..addColumns([count])
      ..where(
        localProducts.workspaceId.equals(workspaceId) &
            localProducts.isDeleted.equals(false),
      );
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> categoryCount(int workspaceId) async {
    final count = countAll();
    final query = selectOnly(localCategories)
      ..addColumns([count])
      ..where(
        localCategories.workspaceId.equals(workspaceId) &
            localCategories.isDeleted.equals(false),
      );
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> tableCount(int workspaceId) async {
    final count = countAll();
    final query = selectOnly(localTables)
      ..addColumns([count])
      ..where(localTables.workspaceId.equals(workspaceId));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// Standalone is ready after a local store exists (empty catalog is valid).
  /// Connected workspaces remain ready after Initial Sync or local products.
  Future<bool> isOfflinePosReady(int workspaceId) async {
    final store = await (select(
      localStores,
    )..where((t) => t.workspaceId.equals(workspaceId))).getSingleOrNull();
    if (store != null) return true;
    if (await hasInitialSync(workspaceId)) return true;
    return (await productCount(workspaceId)) > 0;
  }
}

class SyncMetaKeys {
  static const initialSyncCompleted = 'initial_sync_completed';
  static const syncCursor = 'sync_cursor';
  static const lastPullAt = 'last_pull_at';
  static const lastPushAt = 'last_push_at';
}
