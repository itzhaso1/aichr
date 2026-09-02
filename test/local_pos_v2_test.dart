import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/local_ids.dart';
import 'package:hasim_cashier/core/local_db/workspace_scope.dart';
import 'package:hasim_cashier/core/repositories/catalog_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/repositories/tables_repository.dart';
import 'package:hasim_cashier/core/sync/sync_engine_v2.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
  });

  test('workspace A products never appear under workspace B', () async {
    final now = DateTime.now();
    await db.into(db.localProducts).insert(
          LocalProductsCompanion.insert(
            localId: LocalIds.product(1, 10),
            workspaceId: 1,
            serverId: const Value(10),
            name: 'شاي أ',
            price: const Value(5),
            updatedAt: now,
          ),
        );
    await db.into(db.localProducts).insert(
          LocalProductsCompanion.insert(
            localId: LocalIds.product(2, 10),
            workspaceId: 2,
            serverId: const Value(10),
            name: 'قهوة ب',
            price: const Value(8),
            updatedAt: now,
          ),
        );

    final repo = CatalogRepository(db);
    final a = await repo.products(1);
    final b = await repo.products(2);
    expect(a.single['name'], 'شاي أ');
    expect(b.single['name'], 'قهوة ب');
    expect(await repo.products(3), isEmpty);
  });

  test('offline POS ready only after initial sync flag or local products',
      () async {
    expect(await db.isOfflinePosReady(1), isFalse);
    await db.into(db.localProducts).insert(
          LocalProductsCompanion.insert(
            localId: 'prod_1',
            workspaceId: 1,
            name: 'شاي',
            updatedAt: DateTime.now(),
          ),
        );
    expect(await db.isOfflinePosReady(1), isTrue);
    expect(await db.isOfflinePosReady(2), isFalse);

    await db.markInitialSyncCompleted(2);
    expect(await db.isOfflinePosReady(2), isTrue);
  });

  test('sync queue never drops failed ops and keeps client_reference', () async {
    final queue = SyncQueueRepository(db);
    final id = await queue.enqueue(
      workspaceId: 1,
      deviceId: 'device-1',
      entityType: 'order',
      entityId: 'ABC',
      operation: 'create',
      payload: {
        'order_type': 'table',
        'dining_table_id': 7,
        'client_reference': 'ABC',
        'items': [
          {'pos_menu_item_id': 10, 'quantity': 1},
        ],
      },
      clientReference: 'ABC',
    );
    await queue.markFailed(id, 'timeout', retryable: true);
    final pending = await queue.pendingForWorkspace(1);
    expect(pending, hasLength(1));
    expect(pending.single.clientReference, 'ABC');
    expect(pending.single.status, 'pending');
    expect(pending.single.attempts, 1);

    await queue.markFailed(id, 'validation', retryable: false);
    final failed = await queue.pendingForWorkspace(1);
    expect(failed.single.status, 'failed');
    expect(failed.single.clientReference, 'ABC');
  });

  test('sync engine v2 pushes once with stable idempotency key', () async {
    final now = DateTime.now();
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ABC',
            workspaceId: 1,
            deviceId: 'device-1',
            clientReference: 'ABC',
            orderType: 'table',
            tableServerId: const Value(7),
            createdAt: now,
            updatedAt: now,
          ),
        );
    final queue = SyncQueueRepository(db);
    await queue.enqueue(
      workspaceId: 1,
      deviceId: 'device-1',
      entityType: 'order',
      entityId: 'ABC',
      operation: 'create',
      payload: {
        'order_type': 'table',
        'dining_table_id': 7,
        'client_reference': 'ABC',
        'items': [
          {'pos_menu_item_id': 10, 'quantity': 2},
        ],
      },
      clientReference: 'ABC',
    );

    final keys = <String>[];
    final engine = SyncEngineV2(
      db,
      queue,
      postOrder: (payload, key) async {
        keys.add(key);
        expect(payload['client_reference'], 'ABC');
        return {'id': 99};
      },
    );
    final first = await engine.pushPending(workspaceId: 1);
    expect(first.synced, 1);
    expect(keys, ['ABC']);
    final second = await engine.pushPending(workspaceId: 1);
    expect(second.synced, 0);
    expect(keys, ['ABC']);

    final order = await (db.select(db.localOrders)
          ..where((t) => t.localId.equals('ABC')))
        .getSingle();
    expect(order.serverId, 99);
    expect(order.syncStatus, 'synced');
    expect(order.clientReference, 'ABC');
  });

  test('foreign workspace queue is not pushed', () async {
    final queue = SyncQueueRepository(db);
    await queue.enqueue(
      workspaceId: 1,
      deviceId: 'device-1',
      entityType: 'order',
      entityId: 'WA',
      operation: 'create',
      payload: {'client_reference': 'WA'},
      clientReference: 'WA',
    );
    var posts = 0;
    final engine = SyncEngineV2(
      db,
      queue,
      postOrder: (payload, key) async {
        posts++;
        return {'id': 1};
      },
    );
    final result = await engine.pushPending(workspaceId: 2);
    expect(result.synced, 0);
    expect(posts, 0);
  });

  test('workspace scope rejects invalid workspace id', () {
    expect(
      () => const WorkspaceScope(0).assertValid(),
      throwsA(isA<StateError>()),
    );
  });

  test('tables board reads Local DB with workspace isolation', () async {
    final now = DateTime.now();
    await db.into(db.localTables).insert(
          LocalTablesCompanion.insert(
            localId: TablesRepository.tableLocalId(1, 7),
            workspaceId: 1,
            serverId: const Value(7),
            name: 'طاولة أ',
            status: const Value('occupied'),
            sessionServerId: const Value(100),
            payloadJson: Value(
              jsonEncode({
                'id': 7,
                'name': 'طاولة أ',
                'status': 'occupied',
                'session_id': 100,
                'total': 25.5,
                'orders_count': 2,
              }),
            ),
            updatedAt: now,
          ),
        );
    await db.into(db.localTables).insert(
          LocalTablesCompanion.insert(
            localId: TablesRepository.tableLocalId(2, 7),
            workspaceId: 2,
            serverId: const Value(7),
            name: 'طاولة ب',
            status: const Value('available'),
            payloadJson: Value(
              jsonEncode({
                'id': 7,
                'name': 'طاولة ب',
                'status': 'available',
              }),
            ),
            updatedAt: now,
          ),
        );

    final repo = TablesRepository(db, SyncQueueRepository(db));
    final a = await repo.listTables(1);
    final b = await repo.listTables(2);
    expect(a.single['name'], 'طاولة أ');
    expect(a.single['status'], 'occupied');
    expect(a.single['session_id'], 100);
    expect(a.single['total'], 25.5);
    expect(b.single['name'], 'طاولة ب');
    expect(b.single['status'], 'available');
    expect(await repo.listTables(3), isEmpty);
  });

  test('loadBoard without API returns local tables (offline-capable)', () async {
    await db.into(db.localTables).insert(
          LocalTablesCompanion.insert(
            localId: TablesRepository.tableLocalId(9, 3),
            workspaceId: 9,
            serverId: const Value(3),
            name: 'محلية',
            updatedAt: DateTime.now(),
            payloadJson: Value(jsonEncode({'id': 3, 'name': 'محلية'})),
          ),
        );
    // No API client — repository must still serve SQLite.
    final repo = TablesRepository(db, SyncQueueRepository(db));
    final board = await repo.loadBoard(9);
    expect(board, hasLength(1));
    expect(board.single['id'], 3);
    expect(board.single['name'], 'محلية');
  });

  test('table detail payload preserved when board refresh is thinner', () async {
    final repo = TablesRepository(db, SyncQueueRepository(db));
    await repo.upsertTableDetail(1, 5, {
      'id': 5,
      'name': 'VIP',
      'status': 'occupied',
      'session_id': 55,
      'orders': [
        {'id': 1, 'order_number': 'T-1'},
      ],
      'total': 40,
    });
    await repo.replaceBoard(1, [
      {
        'id': 5,
        'name': 'VIP',
        'status': 'occupied',
        'session_id': 55,
        'orders_count': 1,
      },
    ]);
    final detail = await repo.getTable(1, 5);
    expect(detail != null, isTrue);
    expect(detail!['orders'], isA<List>());
    expect((detail['orders'] as List), hasLength(1));
    expect(detail['total'], 40);
  });
}
