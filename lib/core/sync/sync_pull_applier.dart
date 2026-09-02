import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../local_db/app_database.dart';
import '../pos/domain/pricing_service.dart';
import '../local_db/local_ids.dart';
import '../local_db/workspace_scope.dart';
import '../repositories/sync_conflict_repository.dart';

/// Applies incremental Laravel sync changes inside one SQLite transaction.
/// Cursor advances only after the whole batch commits successfully.
///
/// Strategies:
/// - product / category / table → server authoritative
/// - order → reconcile by client_reference; conflict if local pending diverges
/// - customer → reconcile by client_reference / server_id; conflict if pending
/// - payments / invoices → upsert local cache (server ids); never silent-delete pending
class SyncPullApplier {
  SyncPullApplier(
    this._db, {
    SyncConflictRepository? conflicts,
    String? deviceId,
  })  : _conflicts = conflicts ?? SyncConflictRepository(_db),
        _deviceId = deviceId;

  final AppDatabase _db;
  final SyncConflictRepository _conflicts;
  final String? _deviceId;

  /// Returns the cursor that should be persisted after a successful apply.
  Future<int> applyBatch({
    required int workspaceId,
    required int fromCursor,
    required int responseCursor,
    required List<Map<String, dynamic>> changes,
    String? deviceId,
  }) async {
    if (workspaceId <= 0) {
      throw ArgumentError('workspaceId required');
    }
    final ourDevice = deviceId ?? _deviceId;

    var appliedThrough = fromCursor;
    await _db.transaction(() async {
      for (final change in changes) {
        final version = (change['version'] as num?)?.toInt();
        if (version == null || version <= fromCursor) {
          continue;
        }
        final entity = '${change['entity'] ?? ''}';
        final operation = '${change['operation'] ?? ''}';
        final originDevice = change['origin_device_id']?.toString();
        final data = change['data'] is Map
            ? Map<String, dynamic>.from(change['data'] as Map)
            : <String, dynamic>{};
        final entityId = (change['id'] as num?)?.toInt() ??
            (data['id'] as num?)?.toInt();

        switch (entity) {
          case 'product':
            await _applyProduct(workspaceId, operation, entityId, data);
          case 'category':
            await _applyCategory(workspaceId, operation, entityId, data);
          case 'table':
            await _applyTable(workspaceId, operation, entityId, data);
          case 'order':
            await _applyOrder(
              workspaceId: workspaceId,
              operation: operation,
              serverId: entityId,
              data: data,
              version: version,
              originDeviceId: originDevice,
              ourDeviceId: ourDevice,
            );
          case 'customer':
            await _applyCustomer(
              workspaceId: workspaceId,
              operation: operation,
              serverId: entityId,
              data: data,
              version: version,
              originDeviceId: originDevice,
              ourDeviceId: ourDevice,
            );
          case 'stock':
            await _applyStock(
              workspaceId: workspaceId,
              operation: operation,
              serverId: entityId,
              data: data,
              deviceId: ourDevice,
            );
          case 'payment':
          case 'invoice':
            await _applyInvoiceOrPayment(
              workspaceId: workspaceId,
              entity: entity,
              operation: operation,
              serverId: entityId,
              data: data,
              version: version,
              ourDeviceId: ourDevice,
            );
          default:
            // Forward-compatible: ignore unknown entities without failing sync.
            break;
        }
        appliedThrough = version;
      }

      final cursorToStore =
          changes.isEmpty ? responseCursor : appliedThrough;
      if (cursorToStore < fromCursor) {
        throw StateError('refusing to move cursor backwards');
      }
      await _db.writeCursor(
        workspaceId,
        '$cursorToStore',
        deviceId: ourDevice,
      );
    });

    final stored = await _db.readCursor(workspaceId);
    return int.tryParse(stored ?? '') ?? fromCursor;
  }

  Future<void> _applyProduct(
    int workspaceId,
    String operation,
    int? serverId,
    Map<String, dynamic> data,
  ) async {
    if (serverId == null || serverId <= 0) return;
    final localId = LocalIds.product(workspaceId, serverId);
    if (operation == 'delete') {
      await (_db.update(_db.localProducts)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) &
                (t.localId.equals(localId) | t.serverId.equals(serverId))))
          .write(
        LocalProductsCompanion(
          isDeleted: const Value(true),
          isActive: const Value(false),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return;
    }

    final catServerId = (data['pos_item_category_id'] as num?)?.toInt();
    final now = DateTime.now();
    await _db.into(_db.localProducts).insertOnConflictUpdate(
          LocalProductsCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            serverId: Value(serverId),
            categoryLocalId: Value(
              catServerId == null
                  ? null
                  : LocalIds.category(workspaceId, catServerId),
            ),
            categoryServerId: Value(catServerId),
            name: '${data['name'] ?? ''}',
            sku: Value(data['sku'] as String?),
            barcode: Value(data['barcode'] as String?),
            itemType: Value(data['item_type'] as String?),
            price: Value(Money.toCents((data['price'] as num?) ?? 0)),
            isActive: Value(data['is_active'] != false),
            isDeleted: const Value(false),
            payloadJson: Value(jsonEncode({...data, 'id': serverId})),
            stock: Value((data['stock'] as num?)?.toInt()),
            updatedAt: now,
            serverVersion: Value((data['version'] as num?)?.toInt()),
          ),
        );
  }

  Future<void> _applyCategory(
    int workspaceId,
    String operation,
    int? serverId,
    Map<String, dynamic> data,
  ) async {
    if (serverId == null || serverId <= 0) return;
    final localId = LocalIds.category(workspaceId, serverId);
    if (operation == 'delete') {
      await (_db.update(_db.localCategories)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) &
                (t.localId.equals(localId) | t.serverId.equals(serverId))))
          .write(
        LocalCategoriesCompanion(
          isDeleted: const Value(true),
          isActive: const Value(false),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return;
    }

    await _db.into(_db.localCategories).insertOnConflictUpdate(
          LocalCategoriesCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            serverId: Value(serverId),
            name: '${data['name'] ?? ''}',
            sortOrder: Value((data['sort_order'] as num?)?.toInt() ?? 0),
            isActive: Value(data['is_active'] != false),
            isDeleted: const Value(false),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _applyTable(
    int workspaceId,
    String operation,
    int? serverId,
    Map<String, dynamic> data,
  ) async {
    if (serverId == null || serverId <= 0) return;
    final localId = LocalIds.table(workspaceId, serverId);
    if (operation == 'delete') {
      await (_db.delete(_db.localTables)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) &
                (t.localId.equals(localId) | t.serverId.equals(serverId))))
          .go();
      return;
    }

    await _db.into(_db.localTables).insertOnConflictUpdate(
          LocalTablesCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            serverId: Value(serverId),
            name: '${data['name'] ?? ''}',
            status: Value('${data['status'] ?? 'available'}'),
            capacity: Value((data['capacity'] as num?)?.toInt()),
            sessionServerId: Value((data['session_id'] as num?)?.toInt()),
            payloadJson: Value(jsonEncode({...data, 'id': serverId})),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _applyOrder({
    required int workspaceId,
    required String operation,
    required int? serverId,
    required Map<String, dynamic> data,
    required int version,
    String? originDeviceId,
    String? ourDeviceId,
  }) async {
    final clientRef = '${data['client_reference'] ?? ''}'.trim();
    LocalOrder? local;
    if (clientRef.isNotEmpty) {
      local = await (_db.select(_db.localOrders)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) &
                t.clientReference.equals(clientRef)))
          .getSingleOrNull();
    }
    local ??= serverId == null
        ? null
        : await (_db.select(_db.localOrders)
              ..where((t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.serverId.equals(serverId)))
            .getSingleOrNull();

    final isEcho = ourDeviceId != null &&
        originDeviceId != null &&
        originDeviceId == ourDeviceId;

    if (operation == 'delete') {
      if (local == null) return;
      if (_hasOpenLocalWork(local) && !isEcho) {
        await _conflicts.record(
          workspaceId: workspaceId,
          entityType: 'order',
          entityId: local.localId,
          strategy: 'keep_local_pending',
          reason: 'server_delete_vs_local_pending',
          local: _orderSnapshot(local),
          server: data,
          deviceId: ourDeviceId,
          operation: operation,
          serverVersion: version,
        );
        return;
      }
      await (_db.update(_db.localOrders)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) &
                t.localId.equals(local!.localId)))
          .write(
        LocalOrdersCompanion(
          posStatus: const Value('cancelled'),
          syncStatus: const Value('synced'),
          serverId: Value(serverId ?? local.serverId),
          updatedAt: Value(DateTime.now()),
          syncedAt: Value(DateTime.now()),
        ),
      );
      return;
    }

    if (local != null && _hasOpenLocalWork(local) && !isEcho) {
      // Do not Last-Write-Wins over pending local order work.
      await _conflicts.record(
        workspaceId: workspaceId,
        entityType: 'order',
        entityId: local.localId,
        strategy: 'keep_local_pending',
        reason: 'concurrent_order_edit',
        local: _orderSnapshot(local),
        server: data,
        deviceId: ourDeviceId,
        operation: operation,
        serverVersion: version,
      );
      // Still bind server_id for reconciliation without overwriting items.
      if (serverId != null && local.serverId == null) {
        await (_db.update(_db.localOrders)
              ..where((t) => t.localId.equals(local!.localId)))
            .write(
          LocalOrdersCompanion(
            serverId: Value(serverId),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
      return;
    }

    final localId = local?.localId ??
        (clientRef.isNotEmpty ? clientRef : 'w${workspaceId}_ord_${serverId ?? const Uuid().v4()}');
    final tableServerId = (data['dining_table_id'] as num?)?.toInt();
    final now = DateTime.now();
    await _db.into(_db.localOrders).insertOnConflictUpdate(
          LocalOrdersCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            deviceId: local?.deviceId ?? ourDeviceId ?? 'server',
            serverId: Value(serverId),
            clientReference:
                clientRef.isNotEmpty ? clientRef : localId,
            orderType: '${data['order_type'] ?? local?.orderType ?? 'table'}',
            tableServerId: Value(tableServerId),
            tableLocalId: Value(
              await _db.existingFk(
                'local_tables',
                'local_id',
                tableServerId == null
                    ? null
                    : LocalIds.table(workspaceId, tableServerId),
              ),
            ),
            notes: Value(data['notes'] as String?),
            subtotal: Value(Money.toCents((data['subtotal'] as num?) ?? 0)),
            taxAmount: Value(Money.toCents((data['tax_amount'] as num?) ?? 0)),
            discountAmount:
                Value(Money.toCents((data['discount_amount'] as num?) ?? 0)),
            totalAmount:
                Value(Money.toCents((data['total_amount'] as num?) ?? 0)),
            posStatus: Value('${data['pos_status'] ?? 'new'}'),
            paymentStatus: Value('${data['payment_status'] ?? 'unpaid'}'),
            syncStatus: const Value('synced'),
            createdAt: local?.createdAt ?? now,
            updatedAt: now,
            syncedAt: Value(now),
          ),
        );

    await (_db.delete(_db.localOrderItems)
          ..where((t) =>
              t.orderLocalId.equals(localId) &
              t.workspaceId.equals(workspaceId)))
        .go();

    final items = data['items'] is List ? data['items'] as List : const [];
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final itemServerId = (item['id'] as num?)?.toInt();
      final productServerId = (item['pos_menu_item_id'] as num?)?.toInt();
      final itemLocalId = itemServerId != null
          ? 'w${workspaceId}_oi_$itemServerId'
          : const Uuid().v4();
      await _db.into(_db.localOrderItems).insert(
            LocalOrderItemsCompanion.insert(
              localId: itemLocalId,
              workspaceId: workspaceId,
              orderLocalId: localId,
              serverId: Value(itemServerId),
              productServerId: Value(productServerId),
              productLocalId: Value(
                await _db.existingFk(
                  'local_products',
                  'local_id',
                  productServerId == null
                      ? null
                      : LocalIds.product(workspaceId, productServerId),
                ),
              ),
              name: '${item['product_name'] ?? item['name'] ?? 'صنف'}',
              quantity: (item['quantity'] as num?)?.toInt() ?? 0,
              unitPrice: Money.toCents((item['unit_price'] as num?) ?? 0),
              discountAmount: Value(
                Money.toCents((item['discount_amount'] as num?) ?? 0),
              ),
              totalAmount: Money.toCents((item['total_amount'] as num?) ?? 0),
              updatedAt: now,
            ),
          );
    }
  }

  Future<void> _applyCustomer({
    required int workspaceId,
    required String operation,
    required int? serverId,
    required Map<String, dynamic> data,
    required int version,
    String? originDeviceId,
    String? ourDeviceId,
  }) async {
    final clientRef = '${data['client_reference'] ?? ''}'.trim();
    LocalCustomer? local;
    if (clientRef.isNotEmpty) {
      local = await (_db.select(_db.localCustomers)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) &
                t.localId.equals(clientRef)))
          .getSingleOrNull();
    }
    local ??= serverId == null
        ? null
        : await (_db.select(_db.localCustomers)
              ..where((t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.serverId.equals(serverId)))
            .getSingleOrNull();

    final isEcho = ourDeviceId != null &&
        originDeviceId != null &&
        originDeviceId == ourDeviceId;

    if (operation == 'delete') {
      if (local == null) return;
      await (_db.delete(_db.localCustomers)
            ..where((t) => t.localId.equals(local!.localId)))
          .go();
      return;
    }

    if (local != null &&
        (local.syncStatus == 'pending' || local.syncStatus == 'failed') &&
        !isEcho) {
      await _conflicts.record(
        workspaceId: workspaceId,
        entityType: 'customer',
        entityId: local.localId,
        strategy: 'keep_local_pending',
        reason: 'concurrent_customer_edit',
        local: {
          'name': local.name,
          'phone': local.phone,
          'server_id': local.serverId,
        },
        server: data,
        deviceId: ourDeviceId,
        operation: operation,
        serverVersion: version,
      );
      if (serverId != null && local.serverId == null) {
        await (_db.update(_db.localCustomers)
              ..where((t) => t.localId.equals(local!.localId)))
            .write(LocalCustomersCompanion(serverId: Value(serverId)));
      }
      return;
    }

    final localId = local?.localId ??
        (clientRef.isNotEmpty
            ? clientRef
            : LocalIds.customer(workspaceId, serverId ?? 0));
    await _db.into(_db.localCustomers).insertOnConflictUpdate(
          LocalCustomersCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            serverId: Value(serverId),
            name: '${data['name'] ?? ''}',
            phone: Value(data['phone'] as String?),
            payloadJson: Value(jsonEncode({...data, 'id': serverId})),
            updatedAt: DateTime.now(),
            syncStatus: const Value('synced'),
          ),
        );
  }

  bool _hasOpenLocalWork(LocalOrder order) {
    return order.syncStatus == 'pending' ||
        order.syncStatus == 'syncing' ||
        order.syncStatus == 'failed';
  }

  Map<String, dynamic> _orderSnapshot(LocalOrder order) {
    return {
      'local_id': order.localId,
      'client_reference': order.clientReference,
      'server_id': order.serverId,
      'sync_status': order.syncStatus,
      'total_amount': order.totalAmount,
      'pos_status': order.posStatus,
      'updated_at': order.updatedAt.toIso8601String(),
    };
  }

  Future<void> _applyInvoiceOrPayment({
    required int workspaceId,
    required String entity,
    required String operation,
    required int? serverId,
    required Map<String, dynamic> data,
    required int version,
    required String? ourDeviceId,
  }) async {
    if (operation == 'delete' || serverId == null) return;
    if (entity == 'invoice') {
      final existing = await (_db.select(_db.localInvoices)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) & t.serverId.equals(serverId)))
          .getSingleOrNull();
      final pendingLocal = await (_db.select(_db.localInvoices)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) &
                t.syncStatus.equals('pending')))
          .get();
      // If we have a divergent pending local invoice, record conflict — no LWW.
      if (pendingLocal.isNotEmpty && existing == null) {
        await _conflicts.record(
          workspaceId: workspaceId,
          entityType: 'invoice',
          entityId: '$serverId',
          strategy: 'detect_and_record',
          reason: 'local_pending_invoice_vs_server',
          local: {
            'pending_count': pendingLocal.length,
            'local_ids': [for (final p in pendingLocal) p.localId],
          },
          server: data,
          deviceId: ourDeviceId,
          operation: operation,
          serverVersion: version,
        );
      }
      final invoiceLocalId =
          existing?.localId ?? 'w${workspaceId}_inv_$serverId';
      await _db.into(_db.localInvoices).insertOnConflictUpdate(
            LocalInvoicesCompanion.insert(
              localId: invoiceLocalId,
              workspaceId: workspaceId,
              deviceId: ourDeviceId ?? 'server',
              serverId: Value(serverId),
              invoiceNumber: Value(data['invoice_number']?.toString()),
              totalAmount: Value(
                Money.toCents((data['total_amount'] as num?) ?? 0),
              ),
              syncStatus: const Value('synced'),
              payloadJson: Value(jsonEncode({...data, 'id': serverId})),
              createdAt: existing?.createdAt ?? DateTime.now(),
            ),
          );
      return;
    }
    // payment: informational cache only
    if (serverId <= 0) return;
    final paymentLocalId = 'w${workspaceId}_pay_$serverId';
    await _db.into(_db.localPayments).insertOnConflictUpdate(
          LocalPaymentsCompanion.insert(
            localId: paymentLocalId,
            workspaceId: workspaceId,
            deviceId: ourDeviceId ?? 'server',
            serverId: Value(serverId),
            method: '${data['method'] ?? data['payment_method'] ?? 'cash'}',
            amount: Money.toCents(
              (data['amount'] as num?) ??
                  (data['total_amount'] as num?) ??
                  0,
            ),
            syncStatus: const Value('synced'),
            clientReference: '${data['client_reference'] ?? paymentLocalId}',
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<void> _applyStock({
    required int workspaceId,
    required String operation,
    required int? serverId,
    required Map<String, dynamic> data,
    String? deviceId,
  }) async {
    if (operation == 'delete') return;
    final movementId = serverId ?? (data['id'] as num?)?.toInt();
    final localId = movementId != null
        ? 'w${workspaceId}_stock_$movementId'
        : 'w${workspaceId}_stock_${const Uuid().v4()}';
    final catalogProductId = (data['product_id'] as num?)?.toInt();
    final after = (data['after_quantity'] as num?)?.toInt();
    await _db.into(_db.localStockMovements).insertOnConflictUpdate(
          LocalStockMovementsCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            deviceId: deviceId ?? 'server',
            catalogProductId: Value(catalogProductId),
            kind: '${data['type'] ?? data['kind'] ?? 'adjustment'}',
            quantity: (data['quantity'] as num?)?.toInt() ?? 0,
            referenceType: Value(data['reference_type']?.toString()),
            referenceId: Value(data['reference_id']?.toString()),
            syncStatus: const Value('synced'),
            clientReference: localId,
            payloadJson: Value(jsonEncode(data)),
            createdAt: DateTime.now(),
          ),
        );
    if (catalogProductId == null || after == null) return;
    final products = await (_db.select(_db.localProducts)
          ..where((t) => t.workspaceId.equals(workspaceId)))
        .get();
    for (final product in products) {
      var linked = false;
      try {
        final payload = jsonDecode(product.payloadJson);
        if (payload is Map &&
            (payload['product_id'] as num?)?.toInt() == catalogProductId) {
          linked = true;
        }
      } catch (_) {}
      if (!linked) continue;
      await (_db.update(_db.localProducts)
            ..where((t) => t.localId.equals(product.localId)))
          .write(
        LocalProductsCompanion(
          stock: Value(after),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }
  }
}
