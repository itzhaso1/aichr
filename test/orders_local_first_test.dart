import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/local_ids.dart';
import 'package:hasim_cashier/core/offline/offline_store.dart';
import 'package:hasim_cashier/core/repositories/orders_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/sync/sync_engine_v2.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  late AppDatabase db;
  late SyncQueueRepository queue;
  late OrdersRepository repo;
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('cashier_hive_p3_');
    Hive.init(hiveDir.path);
  });

  setUp(() async {
    db = AppDatabase.memory();
    queue = SyncQueueRepository(db);
    await OfflineStore.instance.init();
    await OfflineStore.instance.clearAllForTest();
    repo = OrdersRepository(db, queue);
  });

  tearDown(() async {
    await OfflineStore.instance.clearAllForTest();
    await db.close();
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDir.exists()) {
      await hiveDir.delete(recursive: true);
    }
  });

  Map<String, dynamic> sampleItem({
    int productId = 10,
    int qty = 2,
    double price = 5,
    String name = 'شاي',
  }) =>
      {
        'pos_menu_item_id': productId,
        'name': name,
        'quantity': qty,
        'unit_price': price,
        'total_amount': qty * price,
      };

  test('create order offline writes order + items + sync_queue atomically',
      () async {
    final created = await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'ORD-CREATE-1',
      items: [sampleItem()],
      notes: 'بدون بصل',
    );
    expect(created['client_reference'], 'ORD-CREATE-1');
    expect(created['local_id'], 'ORD-CREATE-1');
    expect(created['is_local_pending'], isTrue);
    expect(created['total_amount'], 10);
    expect((created['items'] as List), hasLength(1));

    final order = await (db.select(db.localOrders)
          ..where((t) => t.localId.equals('ORD-CREATE-1')))
        .getSingle();
    expect(order.workspaceId, 1);
    expect(order.deviceId, 'device-1');
    expect(order.clientReference, 'ORD-CREATE-1');
    expect(order.tableServerId, 7);
    expect(order.syncStatus, 'pending');

    final items = await (db.select(db.localOrderItems)
          ..where((t) => t.orderLocalId.equals('ORD-CREATE-1')))
        .get();
    expect(items, hasLength(1));
    expect(items.single.productServerId, 10);
    expect(items.single.unitPrice, 500);

    final pending = await queue.pendingForWorkspace(1);
    expect(pending, hasLength(1));
    expect(pending.single.clientReference, 'ORD-CREATE-1');
    expect(pending.single.operation, 'create');
  });

  test('update order offline updates items totals and create payload', () async {
    await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'ORD-UPD-1',
      items: [sampleItem(qty: 1)],
    );
    final ok = await repo.updateLocalOrder(
      workspaceId: 1,
      localId: 'ORD-UPD-1',
      items: [sampleItem(qty: 3, price: 4)],
      notes: 'مضاعف',
    );
    expect(ok, isTrue);
    final order = await repo.getOrder(workspaceId: 1, localId: 'ORD-UPD-1');
    expect(order!['total_amount'], 12);
    expect(order['notes'], 'مضاعف');
    expect((order['items'] as List).single['quantity'], 3);

    final q = await queue.findOpenOp(
      workspaceId: 1,
      entityType: 'order',
      entityId: 'ORD-UPD-1',
      operation: 'create',
    );
    expect(q, isNot(equals(null)));
    expect(q!.payloadJson.contains('"quantity":3'), isTrue);
    expect(q.clientReference, 'ORD-UPD-1');
  });

  test('delete order offline removes order items and cancels queue', () async {
    await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'ORD-DEL-1',
      items: [sampleItem()],
    );
    final ok = await repo.deleteLocalOrder(
      workspaceId: 1,
      localId: 'ORD-DEL-1',
    );
    expect(ok, isTrue);
    expect(await repo.getOrder(workspaceId: 1, localId: 'ORD-DEL-1'), isNull);
    final items = await (db.select(db.localOrderItems)
          ..where((t) => t.orderLocalId.equals('ORD-DEL-1')))
        .get();
    expect(items, isEmpty);
    final open = await queue.findOpenOp(
      workspaceId: 1,
      entityType: 'order',
      entityId: 'ORD-DEL-1',
      operation: 'create',
    );
    expect(open, isNull);
  });

  test('multiple offline orders stay isolated per workspace', () async {
    await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'A-1',
      items: [sampleItem(name: 'أ')],
    );
    await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'A-2',
      items: [sampleItem(name: 'ب')],
    );
    await repo.createTableOrder(
      workspaceId: 2,
      deviceId: 'device-2',
      tableId: 7,
      clientReference: 'B-1',
      items: [sampleItem(name: 'ج')],
    );

    final a = await repo.listUnsyncedForTable(workspaceId: 1, tableId: 7);
    final b = await repo.listUnsyncedForTable(workspaceId: 2, tableId: 7);
    expect(a, hasLength(2));
    expect(b, hasLength(1));
    expect(b.single['client_reference'], 'B-1');
    expect(await repo.listUnsyncedForTable(workspaceId: 1, tableId: 9), isEmpty);
  });

  test('app restart keeps order items totals and sync_queue', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final dir = await Directory.systemTemp.createTemp('pos_v2_restart_');
    final file = File('${dir.path}/pos.sqlite');
    final db1 = AppDatabase.file(file);
    final queue1 = SyncQueueRepository(db1);
    final repo1 = OrdersRepository(db1, queue1);
    await repo1.createTableOrder(
      workspaceId: 9,
      deviceId: 'device-x',
      tableId: 3,
      clientReference: 'RESTART-1',
      items: [sampleItem(qty: 2, price: 7.5)],
      notes: 'restart',
    );
    await db1.close();

    final db2 = AppDatabase.file(file);
    final queue2 = SyncQueueRepository(db2);
    final repo2 = OrdersRepository(db2, queue2);
    final order = await repo2.getOrder(workspaceId: 9, localId: 'RESTART-1');
    expect(order, isNot(equals(null)));
    expect(order!['notes'], 'restart');
    expect(order['total_amount'], 15);
    expect((order['items'] as List), hasLength(1));
    expect(order['client_reference'], 'RESTART-1');
    final pending = await queue2.pendingForWorkspace(9);
    expect(pending, hasLength(1));
    expect(pending.single.clientReference, 'RESTART-1');
    await db2.close();
    await dir.delete(recursive: true);
  });

  test('transaction rollback leaves no orphan order without queue', () async {
    // Empty items rejected before any write.
    expect(
      () => repo.createTableOrder(
        workspaceId: 1,
        deviceId: 'device-1',
        tableId: 7,
        clientReference: 'BAD',
        items: const [],
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await (db.select(db.localOrders).get()), isEmpty);
    expect(await queue.pendingForWorkspace(1), isEmpty);

    // Force mid-transaction failure: create then delete queue row and attempt
    // update which requires open create op → rolls back item rewrite.
    await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'RB-1',
      items: [sampleItem(qty: 1)],
    );
    await queue.cancelOpenOp(
      workspaceId: 1,
      entityType: 'order',
      entityId: 'RB-1',
      operation: 'create',
    );
    expect(
      () => repo.updateLocalOrder(
        workspaceId: 1,
        localId: 'RB-1',
        items: [sampleItem(qty: 9)],
      ),
      throwsA(isA<StateError>()),
    );
    final order = await repo.getOrder(workspaceId: 1, localId: 'RB-1');
    expect(order!['total_amount'], 5); // unchanged
    expect((order['items'] as List).single['quantity'], 1);
  });

  test('sync queue persistence and stable client_reference on retry', () async {
    await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'STABLE-1',
      items: [sampleItem()],
    );
    final keys = <String>[];
    var attempts = 0;
    final engine = SyncEngineV2(
      db,
      queue,
      postOrder: (payload, key) async {
        keys.add(key);
        attempts++;
        if (attempts == 1) {
          throw Exception('network');
        }
        expect(payload['client_reference'], 'STABLE-1');
        return {'id': 501};
      },
    );
    final first = await engine.pushPending(workspaceId: 1);
    expect(first.synced, 0);
    expect(keys, ['STABLE-1']);

    // Clear backoff for immediate retry.
    final row = (await queue.pendingForWorkspace(1)).single;
    await (db.update(db.syncQueueItems)..where((t) => t.id.equals(row.id)))
        .write(const SyncQueueItemsCompanion(nextAttemptAt: Value(null)));

    final second = await engine.pushPending(workspaceId: 1);
    expect(second.synced, 1);
    expect(keys, ['STABLE-1', 'STABLE-1']);

    final order = await (db.select(db.localOrders)
          ..where((t) => t.localId.equals('STABLE-1')))
        .getSingle();
    expect(order.serverId, 501);
    expect(order.clientReference, 'STABLE-1');
    expect(order.syncStatus, 'synced');
  });

  test('no duplicate order after retry with same client_reference', () async {
    await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'IDEM-1',
      items: [sampleItem()],
    );
    // Re-create with same key is idempotent (returns existing).
    final again = await repo.createTableOrder(
      workspaceId: 1,
      deviceId: 'device-1',
      tableId: 7,
      clientReference: 'IDEM-1',
      items: [sampleItem(qty: 9)],
    );
    expect(again['total_amount'], 10);
    expect(await (db.select(db.localOrders).get()), hasLength(1));
    expect(await queue.pendingForWorkspace(1), hasLength(1));

    var posts = 0;
    final engine = SyncEngineV2(
      db,
      queue,
      postOrder: (payload, key) async {
        posts++;
        expect(key, 'IDEM-1');
        return {'id': 77};
      },
    );
    await engine.pushPending(workspaceId: 1);
    await engine.pushPending(workspaceId: 1);
    expect(posts, 1);
  });

  test('Hive pending migrates into SQLite preserving client_reference', () async {
    await OfflineStore.instance.enqueueTableOrder(
      tableId: 4,
      workspaceId: 3,
      idempotencyKey: 'HIVE-MIG-1',
      items: [sampleItem(qty: 2, price: 3)],
      notes: 'from hive',
    );
    final migrated = await repo.migrateHivePending(
      workspaceId: 3,
      deviceId: 'device-m',
    );
    expect(migrated, 1);
    final order = await repo.getOrder(workspaceId: 3, localId: 'HIVE-MIG-1');
    expect(order, isNot(equals(null)));
    expect(order!['client_reference'], 'HIVE-MIG-1');
    expect(order['notes'], 'from hive');
    expect(order['total_amount'], 6);
    expect((order['items'] as List), hasLength(1));

    final q = await queue.pendingForWorkspace(3);
    expect(q.single.clientReference, 'HIVE-MIG-1');

    // Second migrate is a no-op (no duplicate).
    expect(
      await repo.migrateHivePending(workspaceId: 3, deviceId: 'device-m'),
      0,
    );
    expect(await (db.select(db.localOrders).get()), hasLength(1));

    // Hive row still present (not deleted in Phase 3).
    expect(OfflineStore.instance.readPending('HIVE-MIG-1'), isNot(equals(null)));
  });

  test('catalog local ids are workspace scoped', () {
    expect(LocalIds.product(1, 10), 'w1_prod_10');
    expect(LocalIds.product(2, 10), 'w2_prod_10');
    expect(LocalIds.category(1, 5), 'w1_cat_5');
    expect(LocalIds.table(9, 3), 'w9_table_3');
    expect(LocalIds.looksScoped('w1_prod_10'), isTrue);
    expect(LocalIds.looksScoped('prod_10'), isFalse);
  });
}
