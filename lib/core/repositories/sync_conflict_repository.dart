import 'dart:convert';

import 'package:drift/drift.dart';

import '../local_db/app_database.dart';

/// Persists sync conflicts without silently overwriting local or server data.
class SyncConflictRepository {
  SyncConflictRepository(this._db);

  final AppDatabase _db;

  Future<int> record({
    required int workspaceId,
    required String entityType,
    required String entityId,
    required String strategy,
    required String reason,
    required Map<String, dynamic> local,
    required Map<String, dynamic> server,
    String? deviceId,
    String? operation,
    int? localVersion,
    int? serverVersion,
  }) {
    return _db.into(_db.syncConflicts).insert(
          SyncConflictsCompanion.insert(
            workspaceId: workspaceId,
            entityType: entityType,
            entityId: entityId,
            strategy: strategy,
            localJson: jsonEncode({
              ...local,
              if (deviceId != null) 'device_id': deviceId,
              if (operation != null) 'operation': operation,
              if (localVersion != null) 'version': localVersion,
              'reason': reason,
            }),
            serverJson: jsonEncode({
              ...server,
              if (serverVersion != null) 'version': serverVersion,
            }),
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<List<SyncConflict>> openForWorkspace(int workspaceId) {
    return (_db.select(_db.syncConflicts)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) & t.status.equals('open'))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }
}
