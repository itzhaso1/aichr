import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../local_db/app_database.dart';
import '../pos/domain/pricing_service.dart';
import '../local_db/local_ids.dart';
import '../offline/offline_store.dart';
import '../offline/pending_order.dart';
import '../util/json_numbers.dart';
import 'sync_queue_repository.dart';

/// Local-first orders: UI → repository → SQLite transaction → sync_queue.
class OrdersRepository {
  OrdersRepository(
    this._db,
    this._queue, {
    OfflineStore? offlineStore,
    String Function()? newItemId,
  }) : _hive = offlineStore ?? OfflineStore.instance,
       _newItemId = newItemId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final SyncQueueRepository _queue;
  final OfflineStore _hive; // legacy one-shot migration only
  final String Function() _newItemId;

  /// Create a table order atomically with items + sync_queue create.
  /// [clientReference] is durable and must never be rotated later.
  Future<Map<String, dynamic>> createTableOrder({
    required int workspaceId,
    required String deviceId,
    required int tableId,
    required String clientReference,
    required List<Map<String, dynamic>> items,
    String? notes,
  }) async {
    if (workspaceId <= 0) {
      throw ArgumentError('workspaceId required');
    }
    if (deviceId.trim().isEmpty) {
      throw ArgumentError('deviceId required');
    }
    if (tableId <= 0) {
      throw ArgumentError('tableId required');
    }
    final key = clientReference.trim();
    if (key.isEmpty) {
      throw ArgumentError('clientReference required');
    }
    final normalized = _normalizeItems(items);
    if (normalized.isEmpty) {
      throw ArgumentError('items required');
    }

    final existing =
        await (_db.select(_db.localOrders)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.clientReference.equals(key),
            ))
            .getSingleOrNull();
    if (existing != null) {
      return _orderToDisplay(existing, await _itemsFor(existing.localId));
    }

    final now = DateTime.now();
    final totals = _totals(normalized);
    final tableLocalId = LocalIds.table(workspaceId, tableId);
    final apiPayload = _apiCreatePayload(
      orderType: 'table',
      tableId: tableId,
      clientReference: key,
      notes: notes,
      items: normalized,
    );

    await _db.transaction(() async {
      await _db
          .into(_db.localOrders)
          .insert(
            LocalOrdersCompanion.insert(
              localId: key,
              workspaceId: workspaceId,
              deviceId: deviceId.trim(),
              clientReference: key,
              orderType: 'table',
              tableServerId: Value(tableId),
              tableLocalId: Value(
                await _db.existingFk('local_tables', 'local_id', tableLocalId),
              ),
              notes: Value(notes),
              subtotal: Value(Money.toCents(totals.subtotal)),
              taxAmount: const Value(0),
              discountAmount: const Value(0),
              totalAmount: Value(Money.toCents(totals.subtotal)),
              posStatus: const Value('new'),
              paymentStatus: const Value('unpaid'),
              syncStatus: const Value('pending'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final item in normalized) {
        await _db
            .into(_db.localOrderItems)
            .insert(
              LocalOrderItemsCompanion.insert(
                localId: '${item['local_id']}',
                workspaceId: workspaceId,
                orderLocalId: key,
                productServerId: Value(
                  (item['pos_menu_item_id'] as num?)?.toInt(),
                ),
                productLocalId: Value(
                  await _db.existingFk(
                    'local_products',
                    'local_id',
                    (item['pos_menu_item_id'] as num?) == null
                        ? null
                        : LocalIds.product(
                            workspaceId,
                            (item['pos_menu_item_id'] as num).toInt(),
                          ),
                  ),
                ),
                name: '${item['name'] ?? item['product_name'] ?? 'صنف'}',
                quantity: (item['quantity'] as num).toInt(),
                unitPrice: Money.toCents((item['unit_price'] as num?) ?? 0),
                discountAmount: Value(
                  Money.toCents((item['discount_amount'] as num?) ?? 0),
                ),
                totalAmount: Money.toCents(
                  (item['total_amount'] as num?) ??
                      ((item['quantity'] as num).toDouble() *
                          ((item['unit_price'] as num?)?.toDouble() ?? 0)),
                ),
                updatedAt: now,
              ),
            );
      }
      await _queue.enqueue(
        workspaceId: workspaceId,
        deviceId: deviceId.trim(),
        entityType: 'order',
        entityId: key,
        operation: 'create',
        payload: apiPayload,
        clientReference: key,
      );
      await _recordSaleMovements(
        workspaceId: workspaceId,
        deviceId: deviceId.trim(),
        orderLocalId: key,
        items: normalized,
      );
    });

    final order = await (_db.select(
      _db.localOrders,
    )..where((t) => t.localId.equals(key))).getSingle();
    return _orderToDisplay(order, await _itemsFor(key));
  }

  /// Create a takeaway/cart order locally (same sync_queue path as table orders).
  Future<Map<String, dynamic>> createTakeawayOrder({
    required int workspaceId,
    required String deviceId,
    required String clientReference,
    required List<Map<String, dynamic>> items,
    String? notes,
    int? customerServerId,
  }) async {
    if (workspaceId <= 0) throw ArgumentError('workspaceId required');
    if (deviceId.trim().isEmpty) throw ArgumentError('deviceId required');
    final key = clientReference.trim();
    if (key.isEmpty) throw ArgumentError('clientReference required');
    final normalized = _normalizeItems(items);
    if (normalized.isEmpty) throw ArgumentError('items required');

    final existing =
        await (_db.select(_db.localOrders)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.clientReference.equals(key),
            ))
            .getSingleOrNull();
    if (existing != null) {
      return _orderToDisplay(existing, await _itemsFor(existing.localId));
    }

    final now = DateTime.now();
    final totals = _totals(normalized);
    final apiPayload = _apiCreatePayload(
      orderType: 'takeaway',
      tableId: null,
      clientReference: key,
      notes: notes,
      items: normalized,
      customerId: customerServerId,
    );

    await _db.transaction(() async {
      await _db
          .into(_db.localOrders)
          .insert(
            LocalOrdersCompanion.insert(
              localId: key,
              workspaceId: workspaceId,
              deviceId: deviceId.trim(),
              clientReference: key,
              orderType: 'takeaway',
              notes: Value(notes),
              subtotal: Value(Money.toCents(totals.subtotal)),
              taxAmount: const Value(0),
              discountAmount: const Value(0),
              totalAmount: Value(Money.toCents(totals.subtotal)),
              posStatus: const Value('new'),
              paymentStatus: const Value('unpaid'),
              syncStatus: const Value('pending'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final item in normalized) {
        await _db
            .into(_db.localOrderItems)
            .insert(
              LocalOrderItemsCompanion.insert(
                localId: '${item['local_id']}',
                workspaceId: workspaceId,
                orderLocalId: key,
                productServerId: Value(
                  (item['pos_menu_item_id'] as num?)?.toInt(),
                ),
                productLocalId: Value(
                  await _db.existingFk(
                    'local_products',
                    'local_id',
                    (item['pos_menu_item_id'] as num?) == null
                        ? null
                        : LocalIds.product(
                            workspaceId,
                            (item['pos_menu_item_id'] as num).toInt(),
                          ),
                  ),
                ),
                name: '${item['name'] ?? item['product_name'] ?? 'صنف'}',
                quantity: (item['quantity'] as num).toInt(),
                unitPrice: Money.toCents((item['unit_price'] as num?) ?? 0),
                discountAmount: Value(
                  Money.toCents((item['discount_amount'] as num?) ?? 0),
                ),
                totalAmount: Money.toCents(
                  (item['total_amount'] as num?) ??
                      ((item['quantity'] as num).toDouble() *
                          ((item['unit_price'] as num?)?.toDouble() ?? 0)),
                ),
                updatedAt: now,
              ),
            );
      }
      await _queue.enqueue(
        workspaceId: workspaceId,
        deviceId: deviceId.trim(),
        entityType: 'order',
        entityId: key,
        operation: 'create',
        payload: apiPayload,
        clientReference: key,
      );
      await _recordSaleMovements(
        workspaceId: workspaceId,
        deviceId: deviceId.trim(),
        orderLocalId: key,
        items: normalized,
      );
    });

    final order = await (_db.select(
      _db.localOrders,
    )..where((t) => t.localId.equals(key))).getSingle();
    return _orderToDisplay(order, await _itemsFor(key));
  }

  /// Update a local (not-yet-synced or failed) order atomically.
  Future<bool> updateLocalOrder({
    required int workspaceId,
    required String localId,
    required List<Map<String, dynamic>> items,
    String? notes,
  }) async {
    final order = await _getScopedOrder(workspaceId, localId);
    if (order == null) return false;
    if (order.syncStatus == 'synced' || order.serverId != null) return false;
    if (order.syncStatus == 'syncing') return false;

    final normalized = _normalizeItems(items);
    if (normalized.isEmpty) return false;
    final totals = _totals(normalized);
    final now = DateTime.now();
    final apiPayload = _apiCreatePayload(
      orderType: order.orderType,
      tableId: order.tableServerId,
      clientReference: order.clientReference,
      notes: notes,
      items: normalized,
    );

    await _db.transaction(() async {
      await (_db.update(_db.localOrders)..where(
            (t) =>
                t.localId.equals(localId) & t.workspaceId.equals(workspaceId),
          ))
          .write(
            LocalOrdersCompanion(
              notes: Value(notes),
              subtotal: Value(Money.toCents(totals.subtotal)),
              totalAmount: Value(Money.toCents(totals.subtotal)),
              syncStatus: const Value('pending'),
              lastError: const Value(null),
              updatedAt: Value(now),
            ),
          );
      await (_db.delete(_db.localOrderItems)..where(
            (t) =>
                t.orderLocalId.equals(localId) &
                t.workspaceId.equals(workspaceId),
          ))
          .go();
      for (final item in normalized) {
        await _db
            .into(_db.localOrderItems)
            .insert(
              LocalOrderItemsCompanion.insert(
                localId: '${item['local_id']}',
                workspaceId: workspaceId,
                orderLocalId: localId,
                productServerId: Value(
                  (item['pos_menu_item_id'] as num?)?.toInt(),
                ),
                productLocalId: Value(
                  await _db.existingFk(
                    'local_products',
                    'local_id',
                    (item['pos_menu_item_id'] as num?) == null
                        ? null
                        : LocalIds.product(
                            workspaceId,
                            (item['pos_menu_item_id'] as num).toInt(),
                          ),
                  ),
                ),
                name: '${item['name'] ?? item['product_name'] ?? 'صنف'}',
                quantity: (item['quantity'] as num).toInt(),
                unitPrice: Money.toCents((item['unit_price'] as num?) ?? 0),
                discountAmount: Value(
                  Money.toCents((item['discount_amount'] as num?) ?? 0),
                ),
                totalAmount: Money.toCents(
                  (item['total_amount'] as num?) ??
                      ((item['quantity'] as num).toDouble() *
                          ((item['unit_price'] as num?)?.toDouble() ?? 0)),
                ),
                updatedAt: now,
              ),
            );
      }
      final updatedPayload = await _queue.updateOpenPayload(
        workspaceId: workspaceId,
        entityType: 'order',
        entityId: localId,
        operation: 'create',
        payload: apiPayload,
      );
      if (!updatedPayload) {
        throw StateError('sync_queue create op missing for $localId');
      }
    });

    return true;
  }

  /// Delete a local order that never reached the server.
  Future<bool> deleteLocalOrder({
    required int workspaceId,
    required String localId,
  }) async {
    final order = await _getScopedOrder(workspaceId, localId);
    if (order == null) return false;
    if (order.syncStatus == 'synced' || order.serverId != null) return false;
    if (order.syncStatus == 'syncing') return false;

    await _db.transaction(() async {
      final cancelled = await _queue.cancelOpenOp(
        workspaceId: workspaceId,
        entityType: 'order',
        entityId: localId,
        operation: 'create',
      );
      if (!cancelled) {
        throw StateError('cannot cancel sync_queue for $localId');
      }
      await (_db.delete(_db.localOrderItems)..where(
            (t) =>
                t.orderLocalId.equals(localId) &
                t.workspaceId.equals(workspaceId),
          ))
          .go();
      await (_db.delete(_db.localOrders)..where(
            (t) =>
                t.localId.equals(localId) & t.workspaceId.equals(workspaceId),
          ))
          .go();
    });

    return true;
  }

  Future<List<Map<String, dynamic>>> listOrdersForTable({
    required int workspaceId,
    required int tableId,
  }) async {
    if (workspaceId <= 0 || tableId <= 0) return const [];
    final rows =
        await (_db.select(_db.localOrders)
              ..where(
                (t) =>
                    t.workspaceId.equals(workspaceId) &
                    t.tableServerId.equals(tableId),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
            .get();
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      out.add(_orderToDisplay(row, await _itemsFor(row.localId)));
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> listUnsyncedForTable({
    required int workspaceId,
    required int tableId,
  }) async {
    final all = await listOrdersForTable(
      workspaceId: workspaceId,
      tableId: tableId,
    );
    return [
      for (final order in all)
        if (order['is_local_pending'] == true) order,
    ];
  }

  Future<Map<String, dynamic>?> getOrder({
    required int workspaceId,
    required String localId,
  }) async {
    final order = await _getScopedOrder(workspaceId, localId);
    if (order == null) return null;
    return _orderToDisplay(order, await _itemsFor(localId));
  }

  Future<bool> hasUnsyncedForTable({
    required int workspaceId,
    required int tableId,
  }) async {
    final rows = await listUnsyncedForTable(
      workspaceId: workspaceId,
      tableId: tableId,
    );
    return rows.isNotEmpty;
  }

  Future<int> unsyncedCountForTable({
    required int workspaceId,
    required int tableId,
  }) async {
    final rows = await listUnsyncedForTable(
      workspaceId: workspaceId,
      tableId: tableId,
    );
    return rows.length;
  }

  /// Migrate Hive pending orders into SQLite without rotating keys.
  Future<int> migrateHivePending({
    required int workspaceId,
    required String deviceId,
  }) async {
    if (workspaceId <= 0 || deviceId.trim().isEmpty) return 0;
    var migrated = 0;
    List<PendingOrder> hiveOrders;
    try {
      hiveOrders = _hive.unsyncedOrders(workspaceId: workspaceId);
    } catch (_) {
      return 0;
    }
    for (final pending in hiveOrders) {
      if (pending.workspaceId != workspaceId) continue;
      final key = pending.idempotencyKey.trim();
      if (key.isEmpty) continue;
      final existing =
          await (_db.select(_db.localOrders)..where(
                (t) =>
                    t.workspaceId.equals(workspaceId) &
                    t.clientReference.equals(key),
              ))
              .getSingleOrNull();
      if (existing != null) {
        try {
          await _hive.markSynced(key);
        } catch (_) {}
        continue;
      }
      try {
        if (pending.isTableOrder && pending.tableId != null) {
          await createTableOrder(
            workspaceId: workspaceId,
            deviceId: deviceId,
            tableId: pending.tableId!,
            clientReference: key,
            items: pending.items,
            notes: pending.notes,
          );
        } else {
          await createTakeawayOrder(
            workspaceId: workspaceId,
            deviceId: deviceId,
            clientReference: key,
            items: pending.items,
            notes: pending.notes,
          );
        }
        try {
          await _hive.markSynced(key);
        } catch (_) {}
        migrated++;
      } catch (_) {
        // Leave Hive row intact; retry on next boot.
      }
    }
    return migrated;
  }

  /// List local orders for the running POS board (workspace-scoped).
  Future<List<Map<String, dynamic>>> listRunning({
    required int workspaceId,
    int limit = 100,
  }) async {
    if (workspaceId <= 0) return const [];
    final rows =
        await (_db.select(_db.localOrders)
              ..where(
                (t) =>
                    t.workspaceId.equals(workspaceId) &
                    t.posStatus.isNotIn(['cancelled']),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
              ..limit(limit))
            .get();
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      out.add(_orderToDisplay(row, await _itemsFor(row.localId)));
    }
    return out;
  }

  /// Queue an items update for an already-synced order (no silent API from UI).
  Future<bool> enqueueSyncedUpdate({
    required int workspaceId,
    required String deviceId,
    required String localId,
    required Map<String, dynamic> apiPayload,
  }) async {
    final order = await _getScopedOrder(workspaceId, localId);
    if (order == null) return false;
    final serverId = order.serverId;
    if (serverId == null || serverId <= 0) return false;
    if (order.syncStatus == 'syncing') return false;

    final payload = Map<String, dynamic>.from(apiPayload)
      ..['server_order_id'] = serverId
      ..['client_reference'] = order.clientReference;

    await _db.transaction(() async {
      await (_db.update(_db.localOrders)..where(
            (t) =>
                t.localId.equals(localId) & t.workspaceId.equals(workspaceId),
          ))
          .write(
            LocalOrdersCompanion(
              notes: Value(apiPayload['notes'] as String? ?? order.notes),
              syncStatus: const Value('pending'),
              lastError: const Value(null),
              updatedAt: Value(DateTime.now()),
            ),
          );
      final existing = await _queue.findOpenOp(
        workspaceId: workspaceId,
        entityType: 'order',
        entityId: localId,
        operation: 'update',
      );
      if (existing != null && existing.status != 'syncing') {
        await _queue.updateOpenPayload(
          workspaceId: workspaceId,
          entityType: 'order',
          entityId: localId,
          operation: 'update',
          payload: payload,
        );
      } else if (existing == null) {
        await _queue.enqueue(
          workspaceId: workspaceId,
          deviceId: deviceId.trim(),
          entityType: 'order',
          entityId: localId,
          operation: 'update',
          payload: payload,
          clientReference: order.clientReference,
        );
      }
    });
    return true;
  }

  /// Queue delete for an already-synced order.
  Future<bool> enqueueSyncedDelete({
    required int workspaceId,
    required String deviceId,
    required String localId,
  }) async {
    final order = await _getScopedOrder(workspaceId, localId);
    if (order == null) return false;
    final serverId = order.serverId;
    if (serverId == null || serverId <= 0) return false;
    if (order.syncStatus == 'syncing') return false;

    await _db.transaction(() async {
      await (_db.update(_db.localOrders)..where(
            (t) =>
                t.localId.equals(localId) & t.workspaceId.equals(workspaceId),
          ))
          .write(
            LocalOrdersCompanion(
              posStatus: const Value('cancelled'),
              syncStatus: const Value('pending'),
              updatedAt: Value(DateTime.now()),
            ),
          );
      await _queue.enqueue(
        workspaceId: workspaceId,
        deviceId: deviceId.trim(),
        entityType: 'order',
        entityId: localId,
        operation: 'delete',
        payload: {
          'server_order_id': serverId,
          'client_reference': order.clientReference,
        },
        clientReference: '${order.clientReference}-del',
      );
    });
    return true;
  }

  /// Resolve local order by server id within workspace.
  Future<LocalOrder?> findByServerId({
    required int workspaceId,
    required int serverId,
  }) {
    return (_db.select(_db.localOrders)..where(
          (t) =>
              t.workspaceId.equals(workspaceId) & t.serverId.equals(serverId),
        ))
        .getSingleOrNull();
  }

  /// Local-first takeaway/order invoice draft + sync_queue (POST /orders/{id}/invoice).
  Future<Map<String, dynamic>> enqueueInvoiceForOrder({
    required int workspaceId,
    required String deviceId,
    required String orderLocalId,
    String? paymentMethod,
  }) async {
    final order = await _getScopedOrder(workspaceId, orderLocalId);
    if (order == null) {
      throw StateError('الطلب غير موجود محليًا');
    }
    final items = await _itemsFor(orderLocalId);
    final invoiceLocalId = _newItemId();
    final clientRef = '$invoiceLocalId';
    final now = DateTime.now();
    final method = (paymentMethod ?? 'cash').trim();
    final invoiceNumber = 'LOCAL-$invoiceLocalId';
    final invoicePayload = {
      'local_id': invoiceLocalId,
      'invoice_number': invoiceNumber,
      'total_amount': Money.fromCents(order.totalAmount),
      'subtotal': Money.fromCents(order.subtotal),
      'tax_amount': Money.fromCents(order.taxAmount),
      'discount_amount': Money.fromCents(order.discountAmount),
      'payment_method': method,
      'closed_at': now.toUtc().toIso8601String(),
      'order_local_id': orderLocalId,
      'order_server_id': order.serverId,
      'items': [
        for (final item in items)
          {
            'item_name': item.name,
            'quantity': item.quantity,
            'unit_price': Money.fromCents(item.unitPrice),
            'total_amount': Money.fromCents(item.totalAmount),
          },
      ],
      'sync_status': 'pending',
    };

    await _db.transaction(() async {
      await _db
          .into(_db.localInvoices)
          .insert(
            LocalInvoicesCompanion.insert(
              localId: invoiceLocalId,
              workspaceId: workspaceId,
              deviceId: deviceId.trim(),
              invoiceNumber: Value(invoiceNumber),
              totalAmount: Value(order.totalAmount),
              syncStatus: const Value('pending'),
              payloadJson: Value(jsonEncode(invoicePayload)),
              createdAt: now,
            ),
          );
      await _db
          .into(_db.localPayments)
          .insert(
            LocalPaymentsCompanion.insert(
              localId: _newItemId(),
              workspaceId: workspaceId,
              deviceId: deviceId.trim(),
              orderLocalId: Value(orderLocalId),
              invoiceLocalId: Value(invoiceLocalId),
              method: method,
              amount: order.totalAmount,
              syncStatus: const Value('pending'),
              clientReference: clientRef,
              createdAt: now,
            ),
          );
      await (_db.update(_db.localOrders)..where(
            (t) =>
                t.localId.equals(orderLocalId) &
                t.workspaceId.equals(workspaceId),
          ))
          .write(
            LocalOrdersCompanion(
              paymentStatus: const Value('paid'),
              posStatus: const Value('completed'),
              updatedAt: Value(now),
            ),
          );
      await _queue.enqueue(
        workspaceId: workspaceId,
        deviceId: deviceId.trim(),
        entityType: 'invoice',
        entityId: invoiceLocalId,
        operation: 'create',
        payload: {
          'invoice_local_id': invoiceLocalId,
          'order_local_id': orderLocalId,
          'order_server_id': order.serverId,
          'payment_method': method,
        },
        clientReference: clientRef,
      );
    });

    return invoicePayload;
  }

  Future<LocalOrder?> _getScopedOrder(int workspaceId, String localId) {
    return (_db.select(_db.localOrders)..where(
          (t) => t.workspaceId.equals(workspaceId) & t.localId.equals(localId),
        ))
        .getSingleOrNull();
  }

  Future<List<LocalOrderItem>> _itemsFor(String orderLocalId) {
    return (_db.select(_db.localOrderItems)..where(
          (t) =>
              t.orderLocalId.equals(orderLocalId) & t.isRemoved.equals(false),
        ))
        .get();
  }

  List<Map<String, dynamic>> _normalizeItems(List<Map<String, dynamic>> items) {
    final out = <Map<String, dynamic>>[];
    for (final raw in items) {
      final qty = asIntOr(raw['quantity']);
      if (qty <= 0) continue;
      final price = asDoubleOr(raw['unit_price']);
      final total = asDouble(raw['total_amount']) ?? qty * price;
      out.add({
        'local_id': raw['local_id'] ?? _newItemId(),
        'pos_menu_item_id': asInt(raw['pos_menu_item_id']),
        'name': raw['name'] ?? raw['product_name'] ?? 'صنف',
        'product_name': raw['product_name'] ?? raw['name'] ?? 'صنف',
        'variant_name': raw['variant_name'],
        'quantity': qty,
        'unit_price': price,
        'discount_amount': asDoubleOr(raw['discount_amount']),
        'total_amount': total,
      });
    }
    return out;
  }

  ({double subtotal}) _totals(List<Map<String, dynamic>> items) {
    var subtotal = 0.0;
    for (final item in items) {
      subtotal += asDoubleOr(item['total_amount']);
    }
    return (subtotal: subtotal);
  }

  Map<String, dynamic> _apiCreatePayload({
    required String orderType,
    required int? tableId,
    required String clientReference,
    required String? notes,
    required List<Map<String, dynamic>> items,
    int? customerId,
  }) {
    return {
      'order_type': orderType,
      if (tableId != null && tableId > 0) 'dining_table_id': tableId,
      if (customerId != null && customerId > 0) 'customer_id': customerId,
      'client_reference': clientReference,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      'items': [
        for (final item in items)
          {
            'pos_menu_item_id': item['pos_menu_item_id'],
            'quantity': item['quantity'],
          },
      ],
    };
  }

  Map<String, dynamic> _orderToDisplay(
    LocalOrder order,
    List<LocalOrderItem> items,
  ) {
    final unsynced =
        order.syncStatus == 'pending' ||
        order.syncStatus == 'syncing' ||
        order.syncStatus == 'failed';
    return {
      'id': order.serverId ?? order.localId,
      'local_id': order.localId,
      'is_local_pending': unsynced,
      'order_number': order.serverId != null ? '${order.serverId}' : 'محلي',
      'pos_status': order.posStatus,
      'payment_status': order.paymentStatus,
      'sync_status': order.syncStatus,
      'sync_label': switch (order.syncStatus) {
        'pending' => 'بانتظار المزامنة',
        'syncing' => 'جاري المزامنة',
        'failed' => 'فشلت المزامنة',
        'synced' => 'تمت المزامنة',
        _ => order.syncStatus,
      },
      'last_error': order.lastError,
      'notes': order.notes,
      'discount_amount': Money.fromCents(order.discountAmount),
      'tax_amount': Money.fromCents(order.taxAmount),
      'total_amount': Money.fromCents(order.totalAmount),
      'subtotal': Money.fromCents(order.subtotal),
      'client_reference': order.clientReference,
      'dining_table_id': order.tableServerId,
      'workspace_id': order.workspaceId,
      'device_id': order.deviceId,
      'items': [
        for (final item in items)
          {
            'id': item.serverId ?? item.localId,
            'local_id': item.localId,
            'pos_menu_item_id': item.productServerId,
            'product_name': item.name,
            'quantity': item.quantity,
            'unit_price': Money.fromCents(item.unitPrice),
            'discount_amount': Money.fromCents(item.discountAmount),
            'total_amount': Money.fromCents(item.totalAmount),
          },
      ],
    };
  }

  Future<void> _recordSaleMovements({
    required int workspaceId,
    required String deviceId,
    required String orderLocalId,
    required List<Map<String, dynamic>> items,
  }) async {
    final now = DateTime.now();
    for (final item in items) {
      final qty = (item['quantity'] as num?)?.toInt() ?? 0;
      if (qty <= 0) continue;
      final productServerId = (item['pos_menu_item_id'] as num?)?.toInt();
      final productLocalId = productServerId == null
          ? null
          : LocalIds.product(workspaceId, productServerId);
      int? catalogProductId;
      if (productLocalId != null) {
        final product = await (_db.select(
          _db.localProducts,
        )..where((t) => t.localId.equals(productLocalId))).getSingleOrNull();
        if (product != null) {
          try {
            final payload = jsonDecode(product.payloadJson);
            if (payload is Map && payload['product_id'] != null) {
              catalogProductId = (payload['product_id'] as num?)?.toInt();
            }
          } catch (_) {}
          if (product.stock != null) {
            await (_db.update(
              _db.localProducts,
            )..where((t) => t.localId.equals(productLocalId))).write(
              LocalProductsCompanion(
                stock: Value(
                  (product.stock! - qty).clamp(0, 1000000000).toInt(),
                ),
                updatedAt: Value(now),
              ),
            );
          }
        }
      }
      await _db
          .into(_db.localStockMovements)
          .insert(
            LocalStockMovementsCompanion.insert(
              localId: _newItemId(),
              workspaceId: workspaceId,
              deviceId: deviceId,
              productLocalId: Value(
                await _db.existingFk(
                  'local_products',
                  'local_id',
                  productLocalId,
                ),
              ),
              productServerId: Value(productServerId),
              catalogProductId: Value(catalogProductId),
              kind: 'sale',
              quantity: qty,
              referenceType: const Value('order'),
              referenceId: Value(orderLocalId),
              syncStatus: const Value('local'),
              clientReference: _newItemId(),
              payloadJson: Value(jsonEncode({'order_local_id': orderLocalId})),
              createdAt: now,
            ),
          );
    }
  }
}
