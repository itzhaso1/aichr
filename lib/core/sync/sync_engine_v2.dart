import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/cashier_api.dart';
import '../local_db/app_database.dart';
import '../pos/domain/pricing_service.dart';
import '../local_db/workspace_scope.dart';
import '../repositories/sync_queue_repository.dart';
import 'sync_pull_applier.dart';

/// Sync Engine v2 — push SQLite sync_queue, then pull incremental changes.
/// Primary POS sync path (Hive outbox is legacy migration only).
class SyncEngineV2 {
  SyncEngineV2(
    this._db,
    this._queue, {
    CashierApiClient? api,
    SyncPullApplier? pullApplier,
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> payload,
      String idempotencyKey,
    )? postOrder,
    Future<Map<String, dynamic>> Function(
      int serverOrderId,
      Map<String, dynamic> payload,
    )? postOrderItems,
    Future<void> Function(int serverOrderId)? deleteOrder,
    Future<Map<String, dynamic>> Function(int since, int limit)? fetchChanges,
    Future<Map<String, dynamic>> Function(
      int tableServerId,
      String idempotencyKey,
    )? postSessionOpen,
    Future<Map<String, dynamic>> Function(
      int tableServerId,
      int sessionServerId,
      Map<String, dynamic> payload,
      String idempotencyKey,
    )? postSessionClose,
    Future<Map<String, dynamic>> Function(
      int orderServerId,
      String idempotencyKey,
    )? postInvoice,
    Future<Map<String, dynamic>> Function(int tableServerId)? getTable,
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
        postPushBatch,
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body)? postPull,
  })  : _api = api,
        _pullApplier = pullApplier ?? SyncPullApplier(_db),
        _postOrder = postOrder,
        _postOrderItems = postOrderItems,
        _deleteOrder = deleteOrder,
        _fetchChanges = fetchChanges,
        _postSessionOpen = postSessionOpen,
        _postSessionClose = postSessionClose,
        _postInvoice = postInvoice,
        _getTable = getTable,
        _postPushBatch = postPushBatch,
        _postPull = postPull;

  final AppDatabase _db;
  final SyncQueueRepository _queue;
  final CashierApiClient? _api;
  final SyncPullApplier _pullApplier;
  final Future<Map<String, dynamic>> Function(
    Map<String, dynamic> payload,
    String idempotencyKey,
  )? _postOrder;
  final Future<Map<String, dynamic>> Function(
    int serverOrderId,
    Map<String, dynamic> payload,
  )? _postOrderItems;
  final Future<void> Function(int serverOrderId)? _deleteOrder;
  final Future<Map<String, dynamic>> Function(int since, int limit)?
      _fetchChanges;
  final Future<Map<String, dynamic>> Function(
    int tableServerId,
    String idempotencyKey,
  )? _postSessionOpen;
  final Future<Map<String, dynamic>> Function(
    int tableServerId,
    int sessionServerId,
    Map<String, dynamic> payload,
    String idempotencyKey,
  )? _postSessionClose;
  final Future<Map<String, dynamic>> Function(
    int orderServerId,
    String idempotencyKey,
  )? _postInvoice;
  final Future<Map<String, dynamic>> Function(int tableServerId)? _getTable;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
      _postPushBatch;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
      _postPull;

  var _flushing = false;
  bool get isFlushing => _flushing;

  /// Push pending local ops, then pull server deltas. Pull failure never
  /// drops the local sync_queue or pending orders.
  Future<SyncEngineV2Result> syncBidirectional({
    required int workspaceId,
    String? deviceId,
  }) async {
    final push = await pushPending(workspaceId: workspaceId);
    try {
      final pull = await pullChanges(
        workspaceId: workspaceId,
        deviceId: deviceId,
      );
      return SyncEngineV2Result(
        synced: push.synced,
        failed: push.failed,
        keptPending: push.keptPending,
        authRequired: push.authRequired || pull.authRequired,
        skippedInFlight: push.skippedInFlight,
        pulled: pull.pulled,
        cursor: pull.cursor,
        pullFailed: pull.pullFailed,
      );
    } catch (e) {
      // Keep pending local ops + existing cursor intact.
      return SyncEngineV2Result(
        synced: push.synced,
        failed: push.failed,
        keptPending: push.keptPending,
        authRequired: push.authRequired,
        skippedInFlight: push.skippedInFlight,
        pullFailed: true,
        pullError: e.toString(),
      );
    }
  }

  /// After full Initial Sync snapshot, anchor cursor to server head without
  /// re-applying historical create events.
  Future<int> anchorCursorToServerHead({
    required int workspaceId,
    String? deviceId,
  }) async {
    final data = await _loadChanges(since: 0, limit: 0, deviceId: deviceId);
    final serverCursor = (data['server_cursor'] as num?)?.toInt() ??
        (data['cursor'] as num?)?.toInt() ??
        0;
    await _db.writeCursor(workspaceId, '$serverCursor', deviceId: deviceId);
    return serverCursor;
  }

  Future<SyncEngineV2Result> pullChanges({
    required int workspaceId,
    String? deviceId,
    int pageLimit = 200,
  }) async {
    if (workspaceId <= 0) return const SyncEngineV2Result();
    final rawCursor = await _db.readCursor(workspaceId);
    var since = int.tryParse(rawCursor ?? '') ?? 0;
    var pulled = 0;
    var cursor = since;
    var hasMore = true;
    while (hasMore) {
      final data = await _loadChanges(
        since: since,
        limit: pageLimit,
        deviceId: deviceId,
      );
      final changes = <Map<String, dynamic>>[];
      if (data['changes'] is List) {
        for (final item in data['changes'] as List) {
          if (item is Map) changes.add(Map<String, dynamic>.from(item));
        }
      }
      final responseCursor = (data['cursor'] as num?)?.toInt() ?? since;
      cursor = await _pullApplier.applyBatch(
        workspaceId: workspaceId,
        fromCursor: since,
        responseCursor: responseCursor,
        changes: changes,
        deviceId: deviceId,
      );
      pulled += changes.length;
      hasMore = data['has_more'] == true;
      since = cursor;
      if (changes.isEmpty) break;
    }
    await _db.writeMeta(
      workspaceId,
      SyncMetaKeys.lastPullAt,
      DateTime.now().toIso8601String(),
      deviceId: deviceId,
    );
    return SyncEngineV2Result(pulled: pulled, cursor: cursor);
  }

  Future<SyncEngineV2Result> pushPending({required int workspaceId}) async {
    if (_flushing) {
      return const SyncEngineV2Result(skippedInFlight: true);
    }
    if (workspaceId <= 0) {
      return const SyncEngineV2Result();
    }
    _flushing = true;
    var synced = 0;
    var failed = 0;
    var kept = 0;
    try {
      await _queue.recoverStuckSyncing(workspaceId);
      if (_preferBatchPush) {
        final batch = await _pushPendingBatch(workspaceId);
        if (!batch.fellBackToRow) {
          if (batch.synced > 0 || batch.failed == 0) {
            await _db.writeMeta(
              workspaceId,
              SyncMetaKeys.lastPushAt,
              DateTime.now().toIso8601String(),
            );
          }
          return batch.result;
        }
      }
      final rows = await _queue.pendingForWorkspace(workspaceId);
      final ordered = [...rows]..sort((a, b) {
          final pa = _pushPriority(a);
          final pb = _pushPriority(b);
          if (pa != pb) return pa.compareTo(pb);
          return a.createdAt.compareTo(b.createdAt);
        });
      for (final row in ordered) {
        if (row.workspaceId != workspaceId) continue;
        if (row.status == 'cancelled' || row.status == 'synced') continue;
        if (row.status == 'failed') {
          kept++;
          continue;
        }
        if (row.nextAttemptAt != null &&
            row.nextAttemptAt!.isAfter(DateTime.now())) {
          kept++;
          continue;
        }
        final supported = row.entityType == 'order' ||
            row.entityType == 'customer' ||
            row.entityType == 'table_session' ||
            row.entityType == 'invoice';
        if (!supported) {
          kept++;
          continue;
        }

        // Close / takeaway invoice wait until dependent orders are pushed.
        if (row.entityType == 'table_session' && row.operation == 'close') {
          final payload = _decode(row.payloadJson);
          final tableId = (payload['table_server_id'] as num?)?.toInt();
          if (tableId != null &&
              await _hasUnsyncedOrdersForTable(workspaceId, tableId)) {
            kept++;
            continue;
          }
        }
        if (row.entityType == 'table_session' &&
            _isSessionAction(row.operation) &&
            !await _sessionActionReady(row)) {
          kept++;
          continue;
        }
        if (row.entityType == 'invoice' && row.operation == 'create') {
          final payload = _decode(row.payloadJson);
          final orderLocalId = '${payload['order_local_id'] ?? ''}';
          if (orderLocalId.isNotEmpty &&
              await _orderNeedsServerId(workspaceId, orderLocalId)) {
            kept++;
            continue;
          }
        }

        await _queue.markSyncing(row.id);
        try {
          if (row.entityType == 'customer') {
            await _pushCustomer(row);
            synced++;
          } else if (row.entityType == 'table_session' &&
              row.operation == 'open') {
            await _pushSessionOpen(row);
            synced++;
          } else if (row.entityType == 'table_session' &&
              row.operation == 'close') {
            await _pushSessionClose(row);
            synced++;
          } else if (row.entityType == 'table_session' &&
              _isSessionAction(row.operation)) {
            await _pushSessionAction(row);
            synced++;
          } else if (row.entityType == 'invoice') {
            await _pushInvoice(row);
            synced++;
          } else if (row.operation == 'create') {
            await _pushCreate(row);
            synced++;
          } else if (row.operation == 'update') {
            await _pushUpdate(row);
            synced++;
          } else if (row.operation == 'delete') {
            await _pushDelete(row);
            synced++;
          } else {
            await _queue.markFailed(
              row.id,
              'عملية مزامنة غير مدعومة: ${row.operation}',
              retryable: false,
            );
            failed++;
          }
        } on ApiException catch (e) {
          if (e.statusCode == 401) {
            await _queue.markFailed(row.id, e.message, retryable: true);
            return SyncEngineV2Result(
              synced: synced,
              failed: failed,
              keptPending: kept + 1,
              authRequired: true,
            );
          }
          if (e.statusCode == 422 || e.statusCode == 403) {
            await _queue.markFailed(row.id, e.message, retryable: false);
            if (row.entityType == 'order') {
              await _markOrderFailed(row.entityId, e.message);
            } else if (row.entityType == 'customer') {
              await _markCustomerFailed(row.entityId, e.message);
            }
            failed++;
          } else {
            await _queue.markFailed(row.id, e.message, retryable: true);
            if (row.entityType == 'order') {
              await _markOrderPending(row.entityId, e.message);
            } else if (row.entityType == 'customer') {
              await _markCustomerPending(row.entityId, e.message);
            }
            kept++;
          }
        } catch (e) {
          await _queue.markFailed(row.id, e.toString(), retryable: true);
          if (row.entityType == 'order') {
            await _markOrderPending(row.entityId, e.toString());
          } else if (row.entityType == 'customer') {
            await _markCustomerPending(row.entityId, e.toString());
          }
          kept++;
        }
      }
      if (synced > 0) {
        await _db.writeMeta(
          workspaceId,
          SyncMetaKeys.lastPushAt,
          DateTime.now().toIso8601String(),
        );
      }
      return SyncEngineV2Result(
        synced: synced,
        failed: failed,
        keptPending: kept,
      );
    } finally {
      _flushing = false;
    }
  }

  bool get _hasRowInjectors =>
      _postOrder != null ||
      _postOrderItems != null ||
      _deleteOrder != null ||
      _postSessionOpen != null ||
      _postSessionClose != null ||
      _postInvoice != null;

  bool get _preferBatchPush =>
      _postPushBatch != null || (_api != null && !_hasRowInjectors);

  String _operationUuid(SyncQueueItem row) {
    final uuid = row.operationUuid?.trim();
    if (uuid != null && uuid.isNotEmpty) return uuid;
    return '${row.clientReference}:${row.entityType}:${row.operation}:${row.id}';
  }

  String _operationType(SyncQueueItem row) {
    if (row.entityType == 'order') {
      return switch (row.operation) {
        'create' => 'order.created',
        'update' => 'order.updated',
        'delete' => 'order.deleted',
        _ => 'order.${row.operation}',
      };
    }
    if (row.entityType == 'customer') return 'customer.created';
    if (row.entityType == 'invoice') return 'invoice.created';
    if (row.entityType == 'table_session') {
      return 'table_session.${row.operation}';
    }
    if (row.entityType == 'stock' || row.entityType == 'stock_movement') {
      return 'stock.movement';
    }
    return '${row.entityType}.${row.operation}';
  }

  Future<({SyncEngineV2Result result, bool fellBackToRow, int synced, int failed})>
      _pushPendingBatch(int workspaceId) async {
    var synced = 0;
    var failed = 0;
    var kept = 0;
    var authRequired = false;

    for (var round = 0; round < 6; round++) {
      final rows = await _queue.pendingForWorkspace(workspaceId);
      final ordered = [...rows]..sort((a, b) {
          final pa = _pushPriority(a);
          final pb = _pushPriority(b);
          if (pa != pb) return pa.compareTo(pb);
          return a.createdAt.compareTo(b.createdAt);
        });
      final ready = <SyncQueueItem>[];
      kept = 0;
      for (final row in ordered) {
        if (row.workspaceId != workspaceId) continue;
        if (row.status == 'cancelled' || row.status == 'synced') continue;
        if (row.status == 'failed') {
          kept++;
          continue;
        }
        if (row.nextAttemptAt != null &&
            row.nextAttemptAt!.isAfter(DateTime.now())) {
          kept++;
          continue;
        }
        if (!await _rowReadyForPush(row)) {
          kept++;
          continue;
        }
        ready.add(row);
      }
      if (ready.isEmpty) break;

      const chunkSize = 50;
      var sentAny = false;
      for (var i = 0; i < ready.length; i += chunkSize) {
        final chunk = ready.sublist(
          i,
          i + chunkSize > ready.length ? ready.length : i + chunkSize,
        );
        sentAny = true;
        final deviceId = chunk.first.deviceId;
        final operations = [
          for (final row in chunk)
            {
              'id': _operationUuid(row),
              'type': _operationType(row),
              'created_at': row.createdAt.toUtc().toIso8601String(),
              'data': _decode(row.payloadJson),
            },
        ];
        for (final row in chunk) {
          await _queue.markSyncing(row.id);
        }
        try {
          final data = await _sendPushBatch({
            'device_id': deviceId,
            'operations': operations,
          });
          final accepted = _asMapList(data['accepted']);
          final failedOps = _asMapList(data['failed']);
          final byId = <String, SyncQueueItem>{
            for (final row in chunk) _operationUuid(row): row,
          };
          for (final ack in accepted) {
            final id = '${ack['id'] ?? ''}';
            final row = byId.remove(id);
            if (row == null) continue;
            await _applyAcceptedAck(row, ack);
            synced++;
          }
          for (final ack in failedOps) {
            final id = '${ack['id'] ?? ''}';
            final row = byId.remove(id);
            if (row == null) continue;
            final retryable = ack['retryable'] != false;
            await _queue.markFailed(
              row.id,
              '${ack['error'] ?? 'فشلت المزامنة'}',
              retryable: retryable,
            );
            if (retryable) {
              kept++;
            } else {
              failed++;
            }
          }
          for (final leftover in byId.values) {
            await _queue.markFailed(
              leftover.id,
              'لم يُرجع الخادم تأكيداً لهذه العملية',
              retryable: true,
            );
            kept++;
          }
        } on ApiException catch (e) {
          if (e.statusCode == 404) {
            for (final row in chunk) {
              await _queue.markFailed(row.id, e.message, retryable: true);
            }
            return (
              result: const SyncEngineV2Result(),
              fellBackToRow: true,
              synced: 0,
              failed: 0,
            );
          }
          if (e.statusCode == 401) {
            for (final row in chunk) {
              await _queue.markFailed(row.id, e.message, retryable: true);
            }
            authRequired = true;
            kept += chunk.length;
            break;
          }
          for (final row in chunk) {
            await _queue.markFailed(row.id, e.message, retryable: true);
          }
          kept += chunk.length;
        } catch (e) {
          for (final row in chunk) {
            await _queue.markFailed(row.id, e.toString(), retryable: true);
          }
          kept += chunk.length;
        }
      }
      if (authRequired || !sentAny) break;
    }

    return (
      result: SyncEngineV2Result(
        synced: synced,
        failed: failed,
        keptPending: kept,
        authRequired: authRequired,
      ),
      fellBackToRow: false,
      synced: synced,
      failed: failed,
    );
  }

  Future<bool> _rowReadyForPush(SyncQueueItem row) async {
    final supported = row.entityType == 'order' ||
        row.entityType == 'customer' ||
        row.entityType == 'table_session' ||
        row.entityType == 'invoice' ||
        row.entityType == 'stock' ||
        row.entityType == 'stock_movement';
    if (!supported) return false;
    if (row.entityType == 'table_session' && row.operation == 'close') {
      final payload = _decode(row.payloadJson);
      final tableId = (payload['table_server_id'] as num?)?.toInt();
      if (tableId != null &&
          await _hasUnsyncedOrdersForTable(row.workspaceId, tableId)) {
        return false;
      }
    }
    if (row.entityType == 'table_session' &&
        _isSessionAction(row.operation) &&
        !await _sessionActionReady(row)) {
      return false;
    }
    if (row.entityType == 'invoice' && row.operation == 'create') {
      final payload = _decode(row.payloadJson);
      final orderLocalId = '${payload['order_local_id'] ?? ''}';
      if (orderLocalId.isNotEmpty &&
          await _orderNeedsServerId(row.workspaceId, orderLocalId)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _applyAcceptedAck(
    SyncQueueItem row,
    Map<String, dynamic> ack,
  ) async {
    final result = ack['result'] is Map
        ? Map<String, dynamic>.from(ack['result'] as Map)
        : <String, dynamic>{};
    if (ack['entity_id'] != null && result['id'] == null) {
      result['id'] = ack['entity_id'];
    }
    if (row.entityType == 'customer') {
      await _finalizeCustomer(row, result);
    } else if (row.entityType == 'table_session' && row.operation == 'open') {
      await _finalizeSessionOpen(row, result);
    } else if (row.entityType == 'table_session' && row.operation == 'close') {
      await _finalizeSessionClose(row, result);
    } else if (row.entityType == 'table_session') {
      await _queue.markSynced(row.id);
    } else if (row.entityType == 'invoice') {
      await _finalizeInvoice(row, result);
    } else if (row.operation == 'create') {
      await _finalizeOrderCreate(row, result);
    } else if (row.operation == 'update') {
      await _finalizeOrderUpdate(row);
    } else if (row.operation == 'delete') {
      await _finalizeOrderDelete(row);
    } else {
      await _queue.markSynced(row.id);
    }
  }

  List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Future<Map<String, dynamic>> _sendPushBatch(Map<String, dynamic> body) {
    final poster = _postPushBatch;
    if (poster != null) return poster(body);
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngineV2 requires API or postPushBatch');
    }
    return api.post('/sync/push', data: body);
  }

  int _pushPriority(SyncQueueItem row) {
    if (row.entityType == 'customer') return 0;
    if (row.entityType == 'table_session' && row.operation == 'open') return 1;
    if (row.entityType == 'table_session' && _isSessionAction(row.operation)) {
      return 2;
    }
    if (row.entityType == 'order') return 3;
    if (row.entityType == 'invoice') return 4;
    if (row.entityType == 'table_session' && row.operation == 'close') return 5;
    return 9;
  }

  bool _isSessionAction(String operation) =>
      operation == 'cancel' ||
      operation == 'note' ||
      operation == 'discount' ||
      operation == 'transfer' ||
      operation == 'merge' ||
      operation == 'split';

  Future<bool> _sessionActionReady(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    var sessionId = (payload['session_server_id'] as num?)?.toInt();
    if (sessionId != null && sessionId > 0) return true;
    final table = await (_db.select(_db.localTables)
          ..where((t) =>
              t.localId.equals(row.entityId) &
              t.workspaceId.equals(row.workspaceId)))
        .getSingleOrNull();
    sessionId = table?.sessionServerId;
    if (sessionId != null && sessionId > 0) return true;
    // Transfer/merge may have moved session onto target table.
    final targetId = (payload['target_table_id'] as num?)?.toInt();
    if (targetId != null && targetId > 0) {
      final target = await (_db.select(_db.localTables)
            ..where((t) =>
                t.workspaceId.equals(row.workspaceId) &
                t.serverId.equals(targetId)))
          .getSingleOrNull();
      if (target?.sessionServerId != null && target!.sessionServerId! > 0) {
        return true;
      }
    }
    // Split is applied locally via new order create; remote split can wait.
    if (row.operation == 'split') return true;
    return false;
  }

  Future<void> _pushSessionAction(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    final tableId = (payload['table_server_id'] as num?)?.toInt();
    if (tableId == null || tableId <= 0) {
      throw StateError('table_session action requires table_server_id');
    }
    var sessionId = (payload['session_server_id'] as num?)?.toInt();
    if (sessionId == null || sessionId <= 0) {
      final table = await (_db.select(_db.localTables)
            ..where((t) =>
                t.localId.equals(row.entityId) &
                t.workspaceId.equals(row.workspaceId)))
          .getSingleOrNull();
      sessionId = table?.sessionServerId;
    }
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngineV2 requires API for session action');
    }

    // Local split already created a new order; remote split is best-effort.
    if (row.operation == 'split') {
      if (sessionId != null && sessionId > 0) {
        try {
          await api.post(
            '/tables/$tableId/sessions/$sessionId/split',
            data: payload['remote_groups'] ?? {'groups': const []},
            idempotencyKey: row.clientReference,
          );
        } catch (_) {
          // Keep local split; mark synced so we don't block the queue forever.
        }
      }
      await _queue.markSynced(row.id);
      return;
    }

    if (sessionId == null || sessionId <= 0) {
      throw StateError('session_server_id missing for ${row.operation}');
    }

    switch (row.operation) {
      case 'cancel':
        await api.post(
          '/tables/$tableId/sessions/$sessionId/cancel',
          idempotencyKey: row.clientReference,
        );
      case 'note':
        await api.post(
          '/tables/$tableId/sessions/$sessionId/note',
          data: {'notes': payload['notes'] ?? ''},
          idempotencyKey: row.clientReference,
        );
      case 'discount':
        await api.post(
          '/tables/$tableId/sessions/$sessionId/discount',
          data: {'discount_amount': payload['discount_amount'] ?? 0},
          idempotencyKey: row.clientReference,
        );
      case 'transfer':
        await api.post(
          '/tables/$tableId/sessions/$sessionId/transfer',
          data: {'target_table_id': payload['target_table_id']},
          idempotencyKey: row.clientReference,
        );
      case 'merge':
        await api.post(
          '/tables/$tableId/sessions/$sessionId/merge',
          data: {'target_table_id': payload['target_table_id']},
          idempotencyKey: row.clientReference,
        );
      default:
        throw StateError('unsupported session action ${row.operation}');
    }
    await _queue.markSynced(row.id);
  }

  Future<bool> _hasUnsyncedOrdersForTable(int workspaceId, int tableId) async {
    final rows = await (_db.select(_db.localOrders)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) &
              t.tableServerId.equals(tableId) &
              t.posStatus.isNotValue('cancelled') &
              (t.syncStatus.equals('pending') |
                  t.syncStatus.equals('syncing') |
                  t.syncStatus.equals('failed'))))
        .get();
    return rows.isNotEmpty;
  }

  Future<bool> _orderNeedsServerId(int workspaceId, String orderLocalId) async {
    final order = await (_db.select(_db.localOrders)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) &
              t.localId.equals(orderLocalId)))
        .getSingleOrNull();
    if (order == null) return true;
    return order.serverId == null || order.serverId! <= 0;
  }

  Future<void> _finalizeOrderCreate(
    SyncQueueItem row,
    Map<String, dynamic> data,
  ) async {
    final serverId = data['id'] is num
        ? (data['id'] as num).toInt()
        : int.tryParse('${data['id']}');
    await _db.transaction(() async {
      await (_db.update(_db.localOrders)
            ..where((t) =>
                t.localId.equals(row.entityId) &
                t.workspaceId.equals(row.workspaceId)))
          .write(
        LocalOrdersCompanion(
          serverId: Value(serverId),
          syncStatus: const Value('synced'),
          lastError: const Value(null),
          syncedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _queue.markSynced(row.id);
    });
  }

  Future<void> _finalizeOrderUpdate(SyncQueueItem row) async {
    await _db.transaction(() async {
      await (_db.update(_db.localOrders)
            ..where((t) =>
                t.localId.equals(row.entityId) &
                t.workspaceId.equals(row.workspaceId)))
          .write(
        LocalOrdersCompanion(
          syncStatus: const Value('synced'),
          lastError: const Value(null),
          syncedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _queue.markSynced(row.id);
    });
  }

  Future<void> _finalizeOrderDelete(SyncQueueItem row) async {
    await _db.transaction(() async {
      await (_db.update(_db.localOrders)
            ..where((t) =>
                t.localId.equals(row.entityId) &
                t.workspaceId.equals(row.workspaceId)))
          .write(
        LocalOrdersCompanion(
          posStatus: const Value('cancelled'),
          syncStatus: const Value('synced'),
          lastError: const Value(null),
          syncedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _queue.markSynced(row.id);
    });
  }

  Future<void> _finalizeCustomer(
    SyncQueueItem row,
    Map<String, dynamic> data,
  ) async {
    final payload = _decode(row.payloadJson);
    final serverId = data['id'] is num
        ? (data['id'] as num).toInt()
        : int.tryParse('${data['id']}');
    await _db.transaction(() async {
      await (_db.update(_db.localCustomers)
            ..where((t) =>
                t.localId.equals(row.entityId) &
                t.workspaceId.equals(row.workspaceId)))
          .write(
        LocalCustomersCompanion(
          serverId: Value(serverId),
          syncStatus: const Value('synced'),
          name: Value('${data['name'] ?? payload['name'] ?? ''}'),
          phone: Value(data['phone'] as String? ?? payload['phone'] as String?),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _queue.markSynced(row.id);
    });
  }

  Future<void> _finalizeSessionOpen(
    SyncQueueItem row,
    Map<String, dynamic> data,
  ) async {
    final sessionId = (data['session_id'] as num?)?.toInt();
    final now = DateTime.now();
    await _db.transaction(() async {
      final table = await (_db.select(_db.localTables)
            ..where((t) =>
                t.localId.equals(row.entityId) &
                t.workspaceId.equals(row.workspaceId)))
          .getSingleOrNull();
      if (table != null) {
        final prev = _decode(table.payloadJson);
        final next = {
          ...prev,
          'session_id': sessionId,
          'session_open': true,
          'status': 'occupied',
          if (data['opened_at'] != null) 'opened_at': data['opened_at'],
        };
        await (_db.update(_db.localTables)
              ..where((t) => t.localId.equals(table.localId)))
            .write(
          LocalTablesCompanion(
            sessionServerId: Value(sessionId),
            status: const Value('occupied'),
            payloadJson: Value(jsonEncode(next)),
            updatedAt: Value(now),
          ),
        );
      }
      await _queue.markSynced(row.id);
    });
  }

  Future<void> _finalizeSessionClose(
    SyncQueueItem row,
    Map<String, dynamic> data,
  ) async {
    final invoice = data['invoice'] is Map
        ? Map<String, dynamic>.from(data['invoice'] as Map)
        : null;
    await _markInvoiceSyncedFromClose(row, invoice);
    await _queue.markSynced(row.id);
  }

  Future<void> _finalizeInvoice(
    SyncQueueItem row,
    Map<String, dynamic> data,
  ) async {
    final invoiceLocalId = row.entityId;
    final existing = await (_db.select(_db.localInvoices)
          ..where((t) => t.localId.equals(invoiceLocalId)))
        .getSingleOrNull();
    final prev =
        existing == null ? <String, dynamic>{} : _decode(existing.payloadJson);
    final merged = {
      ...prev,
      'id': data['invoice_id'] ?? data['id'],
      'invoice_number': data['invoice_number'],
      'total_amount': data['total_amount'],
      'currency': data['currency'],
      'sync_status': 'synced',
    };
    await _db.transaction(() async {
      await (_db.update(_db.localInvoices)
            ..where((t) => t.localId.equals(invoiceLocalId)))
          .write(
        LocalInvoicesCompanion(
          serverId: Value(
            (data['invoice_id'] as num?)?.toInt() ??
                (data['id'] as num?)?.toInt(),
          ),
          invoiceNumber: Value(data['invoice_number']?.toString()),
          totalAmount: Value(
            data['total_amount'] is num
                ? Money.toCents(data['total_amount'] as num)
                : (existing?.totalAmount ?? 0),
          ),
          syncStatus: const Value('synced'),
          payloadJson: Value(jsonEncode(merged)),
        ),
      );
      await (_db.update(_db.localPayments)
            ..where((t) => t.invoiceLocalId.equals(invoiceLocalId)))
          .write(
        const LocalPaymentsCompanion(syncStatus: Value('synced')),
      );
      await _queue.markSynced(row.id);
    });
  }

  Future<void> _pushSessionOpen(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    final tableId = (payload['table_server_id'] as num?)?.toInt();
    if (tableId == null || tableId <= 0) {
      throw StateError('table_session open requires table_server_id');
    }
    final Map<String, dynamic> data;
    final opener = _postSessionOpen;
    if (opener != null) {
      data = await opener(tableId, row.clientReference);
    } else {
      final api = _api;
      if (api == null) {
        throw StateError('SyncEngineV2 requires API for session open');
      }
      data = await api.post(
        '/tables/$tableId/sessions/open',
        idempotencyKey: row.clientReference,
      );
    }
    await _finalizeSessionOpen(row, data);
  }

  Future<void> _pushSessionClose(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    final tableId = (payload['table_server_id'] as num?)?.toInt();
    if (tableId == null || tableId <= 0) {
      throw StateError('table_session close requires table_server_id');
    }

    var sessionId = (payload['session_server_id'] as num?)?.toInt();
    if (sessionId == null || sessionId <= 0) {
      final table = await (_db.select(_db.localTables)
            ..where((t) =>
                t.localId.equals(row.entityId) &
                t.workspaceId.equals(row.workspaceId)))
          .getSingleOrNull();
      sessionId = table?.sessionServerId;
    }
    if (sessionId == null || sessionId <= 0) {
      final getter = _getTable;
      if (getter != null) {
        final remote = await getter(tableId);
        sessionId = (remote['session_id'] as num?)?.toInt();
      } else {
        final api = _api;
        if (api != null) {
          final remote = await api.get('/tables/$tableId');
          sessionId = (remote['session_id'] as num?)?.toInt();
        }
      }
    }
    if (sessionId == null || sessionId <= 0) {
      // Session may already be closed server-side (e.g. auto-open + empty).
      await _markInvoiceSyncedFromClose(row, null);
      await _queue.markSynced(row.id);
      return;
    }

    final closeBody = <String, dynamic>{
      if (payload['payment_method'] != null)
        'payment_method': payload['payment_method'],
    };
    final Map<String, dynamic> data;
    final closer = _postSessionClose;
    if (closer != null) {
      data = await closer(tableId, sessionId, closeBody, row.clientReference);
    } else {
      final api = _api;
      if (api == null) {
        throw StateError('SyncEngineV2 requires API for session close');
      }
      data = await api.post(
        '/tables/$tableId/sessions/$sessionId/close',
        data: closeBody,
        idempotencyKey: row.clientReference,
      );
    }
    final invoice = data['invoice'] is Map
        ? Map<String, dynamic>.from(data['invoice'] as Map)
        : null;
    await _markInvoiceSyncedFromClose(row, invoice);
    await _queue.markSynced(row.id);
  }

  Future<void> _markInvoiceSyncedFromClose(
    SyncQueueItem row,
    Map<String, dynamic>? invoice,
  ) async {
    final payload = _decode(row.payloadJson);
    final invoiceLocalId = '${payload['invoice_local_id'] ?? ''}';
    final paymentLocalId = '${payload['payment_local_id'] ?? ''}';
    final now = DateTime.now();
    if (invoiceLocalId.isNotEmpty) {
      final existing = await (_db.select(_db.localInvoices)
            ..where((t) => t.localId.equals(invoiceLocalId)))
          .getSingleOrNull();
      final prev = existing == null
          ? <String, dynamic>{}
          : _decode(existing.payloadJson);
      final merged = {
        ...prev,
        if (invoice != null) ...invoice,
        'sync_status': 'synced',
      };
      await (_db.update(_db.localInvoices)
            ..where((t) => t.localId.equals(invoiceLocalId)))
          .write(
        LocalInvoicesCompanion(
          serverId: Value((invoice?['id'] as num?)?.toInt()),
          invoiceNumber: Value(
            invoice?['invoice_number']?.toString() ?? existing?.invoiceNumber,
          ),
          totalAmount: Value(
            invoice?['total_amount'] is num
                ? Money.toCents(invoice?['total_amount'] as num)
                : (existing?.totalAmount ?? 0),
          ),
          syncStatus: const Value('synced'),
          payloadJson: Value(jsonEncode(merged)),
        ),
      );
    }
    if (paymentLocalId.isNotEmpty) {
      await (_db.update(_db.localPayments)
            ..where((t) => t.localId.equals(paymentLocalId)))
          .write(
        const LocalPaymentsCompanion(syncStatus: Value('synced')),
      );
    }
    // Ensure table is available after successful close sync.
    await (_db.update(_db.localTables)
          ..where((t) =>
              t.localId.equals(row.entityId) &
              t.workspaceId.equals(row.workspaceId)))
        .write(
      LocalTablesCompanion(
        status: const Value('available'),
        sessionServerId: const Value(null),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> _pushInvoice(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    var orderServerId = (payload['order_server_id'] as num?)?.toInt();
    final orderLocalId = '${payload['order_local_id'] ?? ''}';
    if ((orderServerId == null || orderServerId <= 0) &&
        orderLocalId.isNotEmpty) {
      final order = await (_db.select(_db.localOrders)
            ..where((t) =>
                t.workspaceId.equals(row.workspaceId) &
                t.localId.equals(orderLocalId)))
          .getSingleOrNull();
      orderServerId = order?.serverId;
    }
    if (orderServerId == null || orderServerId <= 0) {
      throw StateError('invoice create requires synced order_server_id');
    }
    final Map<String, dynamic> data;
    final poster = _postInvoice;
    if (poster != null) {
      data = await poster(orderServerId, row.clientReference);
    } else {
      final api = _api;
      if (api == null) {
        throw StateError('SyncEngineV2 requires API for invoice push');
      }
      data = await api.post(
        '/orders/$orderServerId/invoice',
        idempotencyKey: row.clientReference,
      );
    }
    final invoiceLocalId = row.entityId;
    final existing = await (_db.select(_db.localInvoices)
          ..where((t) => t.localId.equals(invoiceLocalId)))
        .getSingleOrNull();
    final prev =
        existing == null ? <String, dynamic>{} : _decode(existing.payloadJson);
    final merged = {
      ...prev,
      'id': data['invoice_id'],
      'invoice_number': data['invoice_number'],
      'total_amount': data['total_amount'],
      'currency': data['currency'],
      'sync_status': 'synced',
    };
    await _db.transaction(() async {
      await (_db.update(_db.localInvoices)
            ..where((t) => t.localId.equals(invoiceLocalId)))
          .write(
        LocalInvoicesCompanion(
          serverId: Value((data['invoice_id'] as num?)?.toInt()),
          invoiceNumber: Value(data['invoice_number']?.toString()),
          totalAmount: Value(
            data['total_amount'] is num
                ? Money.toCents(data['total_amount'] as num)
                : (existing?.totalAmount ?? 0),
          ),
          syncStatus: const Value('synced'),
          payloadJson: Value(jsonEncode(merged)),
        ),
      );
      await (_db.update(_db.localPayments)
            ..where((t) => t.invoiceLocalId.equals(invoiceLocalId)))
          .write(
        const LocalPaymentsCompanion(syncStatus: Value('synced')),
      );
      await _queue.markSynced(row.id);
    });
  }

  Future<void> _pushCreate(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    payload['client_reference'] = row.clientReference;
    final data = await _sendCreate(payload, row.clientReference);
    await _finalizeOrderCreate(row, data);
  }

  Future<void> _pushCustomer(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    payload['client_reference'] = row.clientReference;
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngineV2 requires API for customer push');
    }
    final data = await api.post(
      '/customers',
      data: payload,
      idempotencyKey: row.clientReference,
    );
    await _finalizeCustomer(row, data);
  }

  Future<void> _pushUpdate(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    final serverId = (payload['server_order_id'] as num?)?.toInt();
    if (serverId == null || serverId <= 0) {
      throw StateError('update requires server_order_id');
    }
    await _sendUpdate(serverId, payload);
    await _finalizeOrderUpdate(row);
  }

  Future<void> _pushDelete(SyncQueueItem row) async {
    final payload = _decode(row.payloadJson);
    final serverId = (payload['server_order_id'] as num?)?.toInt();
    if (serverId == null || serverId <= 0) {
      throw StateError('delete requires server_order_id');
    }
    await _sendDelete(serverId);
    await _finalizeOrderDelete(row);
  }

  Future<void> _markOrderFailed(String localId, String error) async {
    await (_db.update(_db.localOrders)..where((t) => t.localId.equals(localId)))
        .write(
      LocalOrdersCompanion(
        syncStatus: const Value('failed'),
        lastError: Value(error),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> _markOrderPending(String localId, String error) async {
    await (_db.update(_db.localOrders)..where((t) => t.localId.equals(localId)))
        .write(
      LocalOrdersCompanion(
        syncStatus: const Value('pending'),
        lastError: Value(error),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> _markCustomerFailed(String localId, String error) async {
    await (_db.update(_db.localCustomers)
          ..where((t) => t.localId.equals(localId)))
        .write(
      LocalCustomersCompanion(
        syncStatus: const Value('failed'),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> _markCustomerPending(String localId, String error) async {
    await (_db.update(_db.localCustomers)
          ..where((t) => t.localId.equals(localId)))
        .write(
      LocalCustomersCompanion(
        syncStatus: const Value('pending'),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<Map<String, dynamic>> _sendCreate(
    Map<String, dynamic> payload,
    String key,
  ) {
    final poster = _postOrder;
    if (poster != null) return poster(payload, key);
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngineV2 requires API or postOrder');
    }
    return api.post('/orders', data: payload, idempotencyKey: key);
  }

  Future<Map<String, dynamic>> _sendUpdate(
    int serverOrderId,
    Map<String, dynamic> payload,
  ) {
    final poster = _postOrderItems;
    if (poster != null) return poster(serverOrderId, payload);
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngineV2 requires API or postOrderItems');
    }
    return api.post('/orders/$serverOrderId/items', data: payload);
  }

  Future<void> _sendDelete(int serverOrderId) async {
    final deleter = _deleteOrder;
    if (deleter != null) {
      await deleter(serverOrderId);
      return;
    }
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngineV2 requires API or deleteOrder');
    }
    await api.delete('/orders/$serverOrderId');
  }

  Map<String, dynamic> _decode(String raw) {
    if (raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _loadChanges({
    required int since,
    required int limit,
    String? deviceId,
  }) async {
    final fetcher = _fetchChanges;
    if (fetcher != null) return fetcher(since, limit);
    final puller = _postPull;
    if (puller != null) {
      return puller({
        'device_id': deviceId ?? 'unknown',
        'cursor': since,
        'limit': limit,
      });
    }
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngineV2 requires API or fetchChanges');
    }
    try {
      return await api.post('/sync/pull', data: {
        'device_id': deviceId ?? 'unknown',
        'cursor': since,
        'limit': limit,
      });
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        return api.get('/sync/changes', query: {
          'since': since,
          'limit': limit,
        });
      }
      rethrow;
    }
  }
}

class SyncEngineV2Result {
  const SyncEngineV2Result({
    this.synced = 0,
    this.failed = 0,
    this.keptPending = 0,
    this.authRequired = false,
    this.skippedInFlight = false,
    this.pulled = 0,
    this.cursor,
    this.pullFailed = false,
    this.pullError,
  });

  final int synced;
  final int failed;
  final int keptPending;
  final bool authRequired;
  final bool skippedInFlight;
  final int pulled;
  final int? cursor;
  final bool pullFailed;
  final String? pullError;
}
