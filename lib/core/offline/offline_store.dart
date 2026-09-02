import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../util/json_numbers.dart';
import 'pending_order.dart';

export 'pending_order.dart' show SyncStatus, PendingOrder, SyncPolicy, SyncFlushResult, SyncOutcome;

/// Local-first offline store for catalog cache + pending POS orders.
/// Uses the existing Hive boxes — never a second database.
class OfflineStore {
  OfflineStore._();
  static final OfflineStore instance = OfflineStore._();

  static const catalogBox = 'cashier_catalog';
  static const ordersBox = 'cashier_pending_orders';

  late Box _catalog;
  late Box _orders;
  final _uuid = const Uuid();
  var _ready = false;

  Future<void> init() async {
    if (_ready && Hive.isBoxOpen(catalogBox) && Hive.isBoxOpen(ordersBox)) {
      _catalog = Hive.box(catalogBox);
      _orders = Hive.box(ordersBox);
      return;
    }
    _catalog = await Hive.openBox(catalogBox);
    _orders = await Hive.openBox(ordersBox);
    _ready = true;
  }

  Future<void> cacheCatalog(
    List<Map<String, dynamic>> items, {
    int? workspaceId,
  }) async {
    final encoded = jsonEncode(items);
    if (workspaceId != null) {
      await _catalog.put('items_$workspaceId', encoded);
    }
    await _catalog.put('items', encoded);
    await _catalog.put('cached_at', DateTime.now().toIso8601String());
  }

  List<Map<String, dynamic>> readCatalog({int? workspaceId}) {
    if (workspaceId != null) {
      return _decodeMapList(_catalog.get('items_$workspaceId'));
    }
    return _decodeMapList(_catalog.get('items'));
  }

  Future<void> cacheCategories(
    List<Map<String, dynamic>> categories, {
    int? workspaceId,
  }) async {
    final encoded = jsonEncode(categories);
    if (workspaceId != null) {
      await _catalog.put('categories_$workspaceId', encoded);
    }
    await _catalog.put('categories', encoded);
  }

  List<Map<String, dynamic>> readCategories({int? workspaceId}) {
    if (workspaceId != null) {
      return _decodeMapList(_catalog.get('categories_$workspaceId'));
    }
    return _decodeMapList(_catalog.get('categories'));
  }

  String? catalogCachedAt() => _catalog.get('cached_at') as String?;

  bool get hasCachedCatalog => readCatalog().isNotEmpty;

  bool hasCachedCatalogFor(int? workspaceId) =>
      readCatalog(workspaceId: workspaceId).isNotEmpty;

  Future<void> cacheJson(String key, Map<String, dynamic> value) async {
    await _catalog.put(key, jsonEncode(value));
    await _catalog.put('${key}_at', DateTime.now().toIso8601String());
  }

  Map<String, dynamic>? readJson(String key) {
    final raw = _catalog.get(key);
    if (raw is! String || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  String? jsonCachedAt(String key) => _catalog.get('${key}_at') as String?;

  Future<void> cacheList(String key, List<Map<String, dynamic>> value) async {
    await _catalog.put(key, jsonEncode(value));
    await _catalog.put('${key}_at', DateTime.now().toIso8601String());
  }

  List<Map<String, dynamic>> readList(String key) {
    final raw = _catalog.get(key);
    if (raw is! String || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> cacheBootstrap(Map<String, dynamic> data) =>
      cacheJson('bootstrap', data);

  Map<String, dynamic>? readBootstrap() => readJson('bootstrap');

  Future<void> cacheSession(Map<String, dynamic> data) =>
      cacheJson('session', data);

  Map<String, dynamic>? readSession() => readJson('session');

  Future<void> cacheTables(
    List<Map<String, dynamic>> tables, {
    int? workspaceId,
  }) async {
    if (workspaceId != null) {
      await cacheList('tables_$workspaceId', tables);
    }
    await cacheList('tables', tables);
  }

  List<Map<String, dynamic>> readTables({int? workspaceId}) {
    if (workspaceId != null) {
      return readList('tables_$workspaceId');
    }
    return readList('tables');
  }

  Future<void> cacheTableDetail(
    int tableId,
    Map<String, dynamic> detail, {
    int? workspaceId,
  }) =>
      cacheJson(_tableDetailKey(tableId, workspaceId), detail);

  Map<String, dynamic>? readTableDetail(int tableId, {int? workspaceId}) =>
      readJson(_tableDetailKey(tableId, workspaceId));

  String _tableDetailKey(int tableId, int? workspaceId) =>
      workspaceId != null ? 'table_${workspaceId}_$tableId' : 'table_$tableId';

  Map<String, dynamic>? tableFromBoardCache(int tableId, {int? workspaceId}) {
    for (final table in readTables(workspaceId: workspaceId)) {
      if ((table['id'] as num?)?.toInt() == tableId) return table;
    }
    return null;
  }

  Future<void> cacheKitchen(List<Map<String, dynamic>> orders) =>
      cacheList('kitchen', orders);

  List<Map<String, dynamic>> readKitchen() => readList('kitchen');

  Future<void> cacheDailyReport(String date, Map<String, dynamic> data) =>
      cacheJson('report_$date', data);

  Map<String, dynamic>? readDailyReport(String date) =>
      readJson('report_$date');

  /// Enqueue a POS order. [payload.client_reference] becomes the durable
  /// Hive key / Idempotency-Key and is never rotated on retry.
  Future<String> enqueueOrder(
    Map<String, dynamic> payload, {
    int? workspaceId,
    int? tableId,
    List<Map<String, dynamic>>? items,
    String? notes,
  }) async {
    final provided = payload['client_reference'] as String?;
    final key =
        (provided != null && provided.trim().isNotEmpty) ? provided.trim() : _uuid.v4();
    final resolvedTable = tableId ??
        (payload['dining_table_id'] as num?)?.toInt();
    final orderType = '${payload['order_type'] ?? (resolvedTable != null ? 'table' : 'takeaway')}';
    if (workspaceId == null || workspaceId <= 0) {
      throw ArgumentError('workspace id is required to enqueue an order');
    }
    if (orderType == 'table' && (resolvedTable == null || resolvedTable <= 0)) {
      throw ArgumentError('table order requires dining_table_id');
    }
    final snapshot = items ?? _snapshotItems(payload['items']);
    final order = PendingOrder(
      localId: key,
      idempotencyKey: key,
      workspaceId: workspaceId,
      tableId: resolvedTable,
      orderType: orderType,
      items: snapshot,
      notes: notes ?? payload['notes'] as String?,
      createdAt: DateTime.now(),
    );
    final record = order.toRecord();
    record['payload'] = {
      ...payload,
      'client_reference': key,
      if (resolvedTable != null) 'dining_table_id': resolvedTable,
      'order_type': orderType,
    };
    await _orders.put(key, jsonEncode(record));
    return key;
  }

  Future<String> enqueueTableOrder({
    required int tableId,
    required int workspaceId,
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
    String? notes,
  }) {
    if (tableId <= 0) {
      throw ArgumentError('table order requires a valid table id');
    }
    if (idempotencyKey.trim().isEmpty) {
      throw ArgumentError('idempotency key is required');
    }
    return enqueueOrder(
      {
        'order_type': 'table',
        'dining_table_id': tableId,
        'client_reference': idempotencyKey.trim(),
        'notes': notes,
        'items': [
          for (final item in items)
            {
              'pos_menu_item_id': item['pos_menu_item_id'],
              'quantity': item['quantity'],
            },
        ],
      },
      workspaceId: workspaceId,
      tableId: tableId,
      items: items,
      notes: notes,
    );
  }

  List<Map<String, dynamic>> allOrderRecords({int? workspaceId}) {
    final records = <Map<String, dynamic>>[];
    for (final raw in _orders.values.whereType<String>()) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        if (workspaceId != null &&
            (map['workspace_id'] as num?)?.toInt() != workspaceId) {
          continue;
        }
        records.add(map);
      } catch (_) {
        // Skip corrupt Hive rows rather than poisoning the queue.
      }
    }
    records.sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
    return records;
  }

  List<PendingOrder> allPendingOrders({int? workspaceId}) {
    final orders = <PendingOrder>[];
    for (final raw in allOrderRecords(workspaceId: workspaceId)) {
      try {
        orders.add(PendingOrder.fromRecord(raw));
      } catch (_) {}
    }
    return orders;
  }

  List<Map<String, dynamic>> pendingOrders({int? workspaceId}) {
    if (workspaceId != null) {
      return allOrderRecords(workspaceId: workspaceId)
          .where((e) => SyncPolicy.shouldAutoSync(_statusOf(e)))
          .toList();
    }
    return const [];
  }

  List<PendingOrder> unsyncedOrders({int? tableId, int? workspaceId}) {
    return allPendingOrders(workspaceId: workspaceId).where((order) {
      if (!order.isUnsynced) return false;
      if (tableId != null && order.tableId != tableId) return false;
      if (workspaceId != null && order.workspaceId != workspaceId) {
        return false;
      }
      return true;
    }).toList();
  }

  int unsyncedCountForTable(int tableId, {int? workspaceId}) =>
      unsyncedOrders(tableId: tableId, workspaceId: workspaceId).length;

  bool hasUnsyncedTableOrders(int tableId, {int? workspaceId}) =>
      unsyncedCountForTable(tableId, workspaceId: workspaceId) > 0;

  PendingOrder? readPending(String localId) {
    final raw = _rawFor(localId);
    if (raw == null) return null;
    return PendingOrder.fromRecord(raw);
  }

  int pendingCount({int? workspaceId}) => unsyncedOrders(workspaceId: workspaceId)
      .where((o) => o.status != SyncStatus.failed)
      .length;

  Future<void> markSyncing(String localId) async {
    await _patch(localId, (map) {
      map['status'] = SyncStatus.syncing.name;
    });
  }

  Future<void> markSynced(String localId, {int? serverOrderId}) async {
    await _patch(localId, (map) {
      map['status'] = SyncStatus.synced.name;
      map['server_order_id'] = serverOrderId;
      map['synced_at'] = DateTime.now().toIso8601String();
      map['last_error'] = null;
    });
  }

  Future<void> markFailed(String localId, String error) async {
    await _patch(localId, (map) {
      map['status'] = SyncStatus.failed.name;
      map['last_error'] = error;
      final attempts = ((map['attempts'] as num?)?.toInt() ?? 0) + 1;
      map['attempts'] = attempts;
      map['retry_count'] = attempts;
    });
  }

  /// Network / 5xx: stay pending, same idempotency key, bump retry count.
  Future<void> markKeepPending(String localId, String error) async {
    await _patch(localId, (map) {
      map['status'] = SyncStatus.pending.name;
      map['last_error'] = error;
      final attempts = ((map['attempts'] as num?)?.toInt() ?? 0) + 1;
      map['attempts'] = attempts;
      map['retry_count'] = attempts;
    });
  }

  Future<void> retry(String localId) async {
    await _patch(localId, (map) {
      map['status'] = SyncStatus.pending.name;
    });
  }

  Future<bool> updatePendingOrder(
    String localId, {
    required List<Map<String, dynamic>> items,
    String? notes,
  }) async {
    final current = readPending(localId);
    if (current == null || current.status == SyncStatus.synced) return false;
    if (current.status == SyncStatus.syncing) return false;
    final next = current.copyWith(items: items, notes: notes, clearError: true);
    final record = next.toRecord();
    record['payload'] = next.toApiPayload();
    // Idempotency key is immutable.
    record['idempotency_key'] = current.idempotencyKey;
    record['client_reference'] = current.idempotencyKey;
    record['local_id'] = current.localId;
    await _orders.put(_hiveKey(localId) ?? current.localId, jsonEncode(record));
    return true;
  }

  Future<bool> deletePending(String localId) async {
    final current = readPending(localId);
    if (current == null) return false;
    if (current.status == SyncStatus.syncing) return false;
    if (current.status == SyncStatus.synced) return false;
    final key = _hiveKey(localId);
    if (key == null) return false;
    await _orders.delete(key);
    return true;
  }

  /// Never silently delete failed/pending — only prune old synced rows.
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)}) async {
    final cutoff = DateTime.now().subtract(olderThan);
    var removed = 0;
    for (final key in _orders.keys.toList()) {
      final raw = _orders.get(key);
      if (raw is! String) continue;
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (map['status'] != SyncStatus.synced.name) continue;
      final syncedAt = DateTime.tryParse('${map['synced_at'] ?? ''}');
      if (syncedAt != null && syncedAt.isBefore(cutoff)) {
        await _orders.delete(key);
        removed++;
      }
    }
    return removed;
  }

  Future<void> simulateRestart() async {
    if (Hive.isBoxOpen(catalogBox)) await Hive.box(catalogBox).close();
    if (Hive.isBoxOpen(ordersBox)) await Hive.box(ordersBox).close();
    _ready = false;
    await init();
  }

  Future<void> clearAllForTest() async {
    if (!_ready) return;
    await _orders.clear();
    await _catalog.clear();
  }

  List<Map<String, dynamic>> _decodeMapList(dynamic raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, dynamic>> _snapshotItems(dynamic raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) {
      final map = Map<String, dynamic>.from(item);
      final qty = asIntOr(map['quantity'], 1);
      final price = asDoubleOr(map['unit_price']);
      return {
        'pos_menu_item_id': map['pos_menu_item_id'],
        'name': map['name'] ?? map['product_name'],
        'quantity': qty,
        'unit_price': price,
        'total_amount': asDoubleOr(map['total_amount'], qty * price),
      };
    }).toList();
  }

  SyncStatus _statusOf(Map<String, dynamic> raw) {
    final name = '${raw['status'] ?? ''}';
    return SyncStatus.values.firstWhere(
      (s) => s.name == name,
      orElse: () => SyncStatus.pending,
    );
  }

  Map<String, dynamic>? _rawFor(String localId) {
    final key = _hiveKey(localId);
    if (key == null) return null;
    final raw = _orders.get(key);
    if (raw is! String) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  String? _hiveKey(String localId) {
    if (_orders.containsKey(localId)) return localId;
    for (final key in _orders.keys) {
      final raw = _orders.get(key);
      if (raw is! String) continue;
      final map = jsonDecode(raw);
      if (map is Map && '${map['local_id']}' == localId) {
        return key.toString();
      }
    }
    return null;
  }

  Future<void> _patch(
    String localId,
    void Function(Map<String, dynamic> map) update,
  ) async {
    final key = _hiveKey(localId);
    if (key == null) return;
    final raw = _orders.get(key);
    if (raw is! String) return;
    final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    update(map);
    await _orders.put(key, jsonEncode(map));
  }
}
