import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../api/cashier_api.dart';
import '../config/app_config.dart';
import '../pos/domain/pricing_service.dart';
import 'app_database.dart';
import 'local_ids.dart';
import 'workspace_scope.dart';

/// Downloads workspace POS baseline into SQLite using existing Cashier APIs.
/// Does not invent catalog data. After success, offline POS reads become possible.
/// When [AppConfig.offlineOnly] is true, never contacts the network.
class InitialSyncService {
  InitialSyncService(this._db, this._api, {this.deviceId});

  final AppDatabase _db;
  final CashierApiClient _api;
  final String? deviceId;
  final _uuid = const Uuid();

  Future<InitialSyncResult> ensureReady(int workspaceId) async {
    if (workspaceId <= 0) {
      return const InitialSyncResult(
        ready: false,
        message: 'لا توجد مساحة عمل محددة.',
      );
    }
    if (await _db.isOfflinePosReady(workspaceId)) {
      return InitialSyncResult(
        ready: true,
        message: 'Local DB جاهزة',
        fromCache: true,
        productCount: await _db.productCount(workspaceId),
        categoryCount: await _db.categoryCount(workspaceId),
        tableCount: await _db.tableCount(workspaceId),
      );
    }
    if (AppConfig.offlineOnly) {
      return InitialSyncResult(
        ready: true,
        message: 'وضع أوفلاين — بدون مزامنة من الخادم',
        fromCache: true,
        productCount: await _db.productCount(workspaceId),
        categoryCount: await _db.categoryCount(workspaceId),
        tableCount: await _db.tableCount(workspaceId),
      );
    }
    return run(workspaceId);
  }

  Future<InitialSyncResult> run(int workspaceId) async {
    if (workspaceId <= 0) {
      throw ArgumentError('workspaceId required');
    }
    if (AppConfig.offlineOnly) {
      return ensureReady(workspaceId);
    }

    final bootstrap = await _api.get('/bootstrap');
    final categoriesData = await _api.get('/catalog/categories');
    final itemsData =
        await _api.get('/catalog/items', query: {'per_page': 200});
    final tablesData = await _api.get('/tables');

    final categories = <Map<String, dynamic>>[];
    if (categoriesData['categories'] is List) {
      for (final c in categoriesData['categories'] as List) {
        if (c is Map) categories.add(Map<String, dynamic>.from(c));
      }
    }
    final items = <Map<String, dynamic>>[];
    if (itemsData['items'] is List) {
      for (final i in itemsData['items'] as List) {
        if (i is Map) items.add(Map<String, dynamic>.from(i));
      }
    }
    final tables = <Map<String, dynamic>>[];
    if (tablesData['tables'] is List) {
      for (final t in tablesData['tables'] as List) {
        if (t is Map) tables.add(Map<String, dynamic>.from(t));
      }
    }

    if (items.isEmpty) {
      return const InitialSyncResult(
        ready: false,
        message:
            'الكتالوج فارغ على السيرفر. لا يمكن تفعيل Offline POS بدون أصناف.',
      );
    }

    final now = DateTime.now();
    await _db.transaction(() async {
      if (deviceId != null) {
        await _db.into(_db.localDevices).insertOnConflictUpdate(
              LocalDevicesCompanion.insert(
                deviceId: deviceId!,
                workspaceId: Value(workspaceId),
                name: const Value('كاشير حاسم'),
                registeredAt: Value(now),
                lastSeenAt: Value(now),
              ),
            );
      }

      // Drop legacy unscoped catalog rows for this workspace before rewrite.
      await (_db.delete(_db.localCategories)
            ..where((t) => t.workspaceId.equals(workspaceId)))
          .go();
      await (_db.delete(_db.localProducts)
            ..where((t) => t.workspaceId.equals(workspaceId)))
          .go();

      for (final cat in categories) {
        final serverId = (cat['id'] as num?)?.toInt();
        final localId = serverId != null
            ? LocalIds.category(workspaceId, serverId)
            : 'w${workspaceId}_cat_${_uuid.v4()}';
        await _db.into(_db.localCategories).insertOnConflictUpdate(
              LocalCategoriesCompanion.insert(
                localId: localId,
                workspaceId: workspaceId,
                serverId: Value(serverId),
                name: '${cat['name'] ?? ''}',
                sortOrder: Value((cat['sort_order'] as num?)?.toInt() ?? 0),
                isActive: Value(cat['is_active'] != false),
                isDeleted: const Value(false),
                updatedAt: now,
              ),
            );
      }

      for (final item in items) {
        final serverId = (item['id'] as num?)?.toInt();
        final catServerId = (item['pos_item_category_id'] as num?)?.toInt();
        final localId = serverId != null
            ? LocalIds.product(workspaceId, serverId)
            : 'w${workspaceId}_prod_${_uuid.v4()}';
        await _db.into(_db.localProducts).insertOnConflictUpdate(
              LocalProductsCompanion.insert(
                localId: localId,
                workspaceId: workspaceId,
                serverId: Value(serverId),
                categoryLocalId: Value(
                  catServerId != null
                      ? LocalIds.category(workspaceId, catServerId)
                      : null,
                ),
                categoryServerId: Value(catServerId),
                name: '${item['name'] ?? ''}',
                sku: Value(item['sku'] as String?),
                barcode: Value(item['barcode'] as String?),
                itemType: Value(item['item_type'] as String?),
                price: Value(Money.toCents((item['price'] as num?) ?? 0)),
                isActive: Value(item['is_active'] != false),
                isDeleted: const Value(false),
                payloadJson: Value(jsonEncode(item)),
                stock: Value((item['stock'] as num?)?.toInt()),
                updatedAt: now,
              ),
            );
      }

      for (final table in tables) {
        final serverId = (table['id'] as num?)?.toInt();
        final localId = serverId != null
            ? LocalIds.table(workspaceId, serverId)
            : 'w${workspaceId}_table_${_uuid.v4()}';
        await _db.into(_db.localTables).insertOnConflictUpdate(
              LocalTablesCompanion.insert(
                localId: localId,
                workspaceId: workspaceId,
                serverId: Value(serverId),
                name: '${table['name'] ?? ''}',
                status: Value('${table['status'] ?? 'available'}'),
                capacity: Value((table['capacity'] as num?)?.toInt()),
                sessionServerId:
                    Value((table['session_id'] as num?)?.toInt()),
                payloadJson: Value(jsonEncode(table)),
                updatedAt: now,
              ),
            );
      }

      final settings = bootstrap['settings'];
      if (settings is Map) {
        await _db.into(_db.localSettings).insertOnConflictUpdate(
              LocalSettingsCompanion.insert(
                key: 'pos',
                workspaceId: workspaceId,
                valueJson: jsonEncode(settings),
                updatedAt: now,
              ),
            );
      }
      final permissions = bootstrap['permissions'];
      final userId = (bootstrap['user'] is Map)
          ? ((bootstrap['user'] as Map)['id'] as num?)?.toInt()
          : null;
      if (permissions is Map && userId != null) {
        for (final entry in permissions.entries) {
          await _db.into(_db.localPermissions).insertOnConflictUpdate(
                LocalPermissionsCompanion.insert(
                  key: '${entry.key}',
                  workspaceId: workspaceId,
                  userId: userId,
                  allowed: Value(entry.value == true),
                  updatedAt: now,
                ),
              );
        }
      }

      await _db.markInitialSyncCompleted(workspaceId, deviceId: deviceId);
      await _db.writeCursor(
        workspaceId,
        now.toUtc().toIso8601String(),
        deviceId: deviceId,
      );
    });

    return InitialSyncResult(
      ready: true,
      message: 'اكتمل Initial Sync',
      fromCache: false,
      productCount: items.length,
      categoryCount: categories.length,
      tableCount: tables.length,
    );
  }
}

class InitialSyncResult {
  const InitialSyncResult({
    required this.ready,
    required this.message,
    this.fromCache = false,
    this.productCount = 0,
    this.categoryCount = 0,
    this.tableCount = 0,
  });

  final bool ready;
  final String message;
  final bool fromCache;
  final int productCount;
  final int categoryCount;
  final int tableCount;
}
