import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/cashier_api.dart';
import 'offline_store.dart';

/// Sync engine:
/// Local Order → Pending → Syncing → POST /orders (same Idempotency-Key) → Synced | Failed | Pending
///
/// Never drops a failed/pending order silently.
/// Never rotates the idempotency key on retry.
class SyncEngine {
  SyncEngine(
    this._store, {
    CashierApiClient? api,
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> payload,
      String idempotencyKey,
    )? postOrder,
  })  : _api = api,
        _postOrder = postOrder;

  final CashierApiClient? _api;
  final OfflineStore _store;
  final Future<Map<String, dynamic>> Function(
    Map<String, dynamic> payload,
    String idempotencyKey,
  )? _postOrder;

  var _flushing = false;

  bool get isFlushing => _flushing;

  Future<Map<String, dynamic>> _send(
    Map<String, dynamic> payload,
    String key,
  ) {
    final poster = _postOrder;
    if (poster != null) return poster(payload, key);
    final api = _api;
    if (api == null) {
      throw StateError('SyncEngine requires an API client or postOrder');
    }
    return api.post('/orders', data: payload, idempotencyKey: key);
  }

  Future<SyncFlushResult> flushPendingOrders({int? workspaceId}) async {
    if (_flushing) {
      return const SyncFlushResult(skippedInFlight: true);
    }
    _flushing = true;
    var synced = 0;
    var failed = 0;
    var keptPending = 0;
    var authRequired = false;

    try {
      final recovered = _store.allPendingOrders();
      for (final record in recovered) {
        if (record.status == SyncStatus.syncing) {
          await _store.retry(record.localId);
        }
      }

      final queue = _store.allPendingOrders()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final record in queue) {
        if (!SyncPolicy.shouldAutoSync(record.status)) continue;
        // Fail-closed: never POST another tenant's order, and never
        // markFailed a foreign record just because this session is open.
        if (workspaceId == null ||
            record.workspaceId == null ||
            record.workspaceId != workspaceId) {
          continue;
        }
        if (record.orderType == 'table' &&
            (record.tableId == null || record.tableId! <= 0)) {
          await _store.markFailed(
            record.localId,
            'لا يمكن مزامنة طلب طاولة بدون رقم الطاولة.',
          );
          failed++;
          continue;
        }

        await _store.markSyncing(record.localId);
        final payload = record.toApiPayload();
        // Force table identity so a retry cannot land on the wrong table.
        if (record.tableId != null) {
          payload['dining_table_id'] = record.tableId;
          payload['order_type'] = 'table';
        }
        payload['client_reference'] = record.idempotencyKey;

        try {
          final data = await _send(payload, record.idempotencyKey);
          final serverId = data['id'] is num
              ? (data['id'] as num).toInt()
              : int.tryParse('${data['id']}');
          await _store.markSynced(record.localId, serverOrderId: serverId);
          synced++;
        } on ApiException catch (e) {
          final outcome = SyncPolicy.fromStatusCode(
            e.statusCode,
            success: false,
          );
          switch (outcome) {
            case SyncOutcome.stopAuth:
              await _store.markKeepPending(
                record.localId,
                e.message,
              );
              authRequired = true;
              keptPending++;
              return SyncFlushResult(
                synced: synced,
                failed: failed,
                keptPending: keptPending,
                authRequired: true,
              );
            case SyncOutcome.markFailed:
              await _store.markFailed(record.localId, e.message);
              failed++;
            case SyncOutcome.keepPending:
              await _store.markKeepPending(record.localId, e.message);
              keptPending++;
            case SyncOutcome.markSynced:
              break;
          }
        } catch (e) {
          await _store.markKeepPending(record.localId, e.toString());
          keptPending++;
        }
      }
      await _store.pruneSynced();
      return SyncFlushResult(
        synced: synced,
        failed: failed,
        keptPending: keptPending,
        authRequired: authRequired,
      );
    } finally {
      _flushing = false;
    }
  }

  Future<bool> retryOne(String localId, {int? workspaceId}) async {
    final pending = _store.readPending(localId);
    if (pending == null) return false;
    if (pending.workspaceId == null) return false;
    if (workspaceId == null || pending.workspaceId != workspaceId) {
      return false;
    }
    if (pending.status == SyncStatus.synced) return true;
    if (pending.status == SyncStatus.syncing) return false;
    await _store.retry(localId);
    final result = await flushPendingOrders(workspaceId: workspaceId);
    if (result.skippedInFlight) return false;
    final after = _store.readPending(localId);
    return after?.status == SyncStatus.synced ||
        (after != null && after.status != pending.status);
  }
}

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    OfflineStore.instance,
    api: ref.watch(cashierApiProvider),
  );
});
