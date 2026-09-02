import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/local_ids.dart';
import 'package:hasim_cashier/core/local_db/workspace_scope.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/sync/sync_engine_v2.dart';
import 'package:hasim_cashier/core/sync/sync_pull_applier.dart';

void main() {
  late AppDatabase db;
  late SyncQueueRepository queue;

  setUp(() {
    db = AppDatabase.memory();
    queue = SyncQueueRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('pull applies product/category/table and advances cursor atomically',
      () async {
    await db.writeCursor(1, '10');
    final engine = SyncEngineV2(
      db,
      queue,
      fetchChanges: (since, limit) async {
        expect(since, 10);
        return {
          'cursor': 13,
          'server_cursor': 13,
          'has_more': false,
          'changes': [
            {
              'version': 11,
              'entity': 'category',
              'operation': 'create',
              'id': 5,
              'data': {'id': 5, 'name': 'مشروبات', 'is_active': true},
            },
            {
              'version': 12,
              'entity': 'product',
              'operation': 'create',
              'id': 9,
              'data': {
                'id': 9,
                'name': 'شاي',
                'price': 5,
                'pos_item_category_id': 5,
                'is_active': true,
              },
            },
            {
              'version': 13,
              'entity': 'table',
              'operation': 'create',
              'id': 3,
              'data': {'id': 3, 'name': 'T1', 'status': 'available'},
            },
          ],
        };
      },
    );

    final result = await engine.pullChanges(workspaceId: 1, deviceId: 'dev');
    expect(result.pulled, 3);
    expect(result.cursor, 13);
    expect(await db.readCursor(1), '13');

    final product = await (db.select(db.localProducts)
          ..where((t) => t.localId.equals(LocalIds.product(1, 9))))
        .getSingle();
    expect(product.name, 'شاي');
    expect(product.workspaceId, 1);

    final category = await (db.select(db.localCategories)
          ..where((t) => t.localId.equals(LocalIds.category(1, 5))))
        .getSingle();
    expect(category.name, 'مشروبات');

    final table = await (db.select(db.localTables)
          ..where((t) => t.localId.equals(LocalIds.table(1, 3))))
        .getSingle();
    expect(table.name, 'T1');
  });

  test('failed pull batch does not advance cursor or drop pending queue',
      () async {
    await db.writeCursor(1, '20');
    await queue.enqueue(
      workspaceId: 1,
      deviceId: 'dev',
      entityType: 'order',
      entityId: 'KEEP',
      operation: 'create',
      payload: {'client_reference': 'KEEP'},
      clientReference: 'KEEP',
    );

    final engine = SyncEngineV2(
      db,
      queue,
      fetchChanges: (since, limit) async {
        throw Exception('network while pulling');
      },
    );
    final result = await engine.syncBidirectional(workspaceId: 1);
    expect(result.pullFailed, isTrue);
    expect(await db.readCursor(1), '20');
    expect(await queue.pendingCount(1), 1);
  });

  test('delete change soft-deletes local product', () async {
    await db.into(db.localProducts).insert(
          LocalProductsCompanion.insert(
            localId: LocalIds.product(1, 8),
            workspaceId: 1,
            serverId: const Value(8),
            name: 'قديم',
            updatedAt: DateTime.now(),
          ),
        );
    await SyncPullApplier(db).applyBatch(
      workspaceId: 1,
      fromCursor: 0,
      responseCursor: 1,
      changes: [
        {
          'version': 1,
          'entity': 'product',
          'operation': 'delete',
          'id': 8,
          'data': {'id': 8, 'deleted': true},
        },
      ],
    );
    final row = await (db.select(db.localProducts)
          ..where((t) => t.localId.equals(LocalIds.product(1, 8))))
        .getSingle();
    expect(row.isDeleted, isTrue);
    expect(await db.readCursor(1), '1');
  });

  test('push then pull keeps pending on pull failure', () async {
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'P1',
            workspaceId: 1,
            deviceId: 'dev',
            clientReference: 'P1',
            orderType: 'table',
            tableServerId: const Value(7),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
    await queue.enqueue(
      workspaceId: 1,
      deviceId: 'dev',
      entityType: 'order',
      entityId: 'P1',
      operation: 'create',
      payload: {
        'order_type': 'table',
        'dining_table_id': 7,
        'client_reference': 'P1',
        'items': [
          {'pos_menu_item_id': 1, 'quantity': 1},
        ],
      },
      clientReference: 'P1',
    );

    final engine = SyncEngineV2(
      db,
      queue,
      postOrder: (payload, key) async => {'id': 99},
      fetchChanges: (since, limit) async {
        throw Exception('pull down');
      },
    );

    final result = await engine.syncBidirectional(workspaceId: 1);
    expect(result.synced, 1);
    expect(result.pullFailed, isTrue);
    final order = await (db.select(db.localOrders)
          ..where((t) => t.localId.equals('P1')))
        .getSingle();
    expect(order.serverId, 99);
    expect(order.syncStatus, 'synced');
    // No cursor written because pull failed before apply.
    expect(await db.readCursor(1), isNull);
  });

  test('workspace B pull data never applied under workspace A cursor', () async {
    final engine = SyncEngineV2(
      db,
      queue,
      fetchChanges: (since, limit) async => {
        'cursor': 1,
        'server_cursor': 1,
        'has_more': false,
        'changes': [
          {
            'version': 1,
            'entity': 'product',
            'operation': 'create',
            'id': 100,
            'data': {'id': 100, 'name': 'B-only', 'price': 1},
          },
        ],
      },
    );
    await engine.pullChanges(workspaceId: 2);
    expect(await (db.select(db.localProducts)
          ..where((t) => t.workspaceId.equals(1)))
        .get(), isEmpty);
    expect(await (db.select(db.localProducts)
          ..where((t) => t.workspaceId.equals(2)))
        .get(), hasLength(1));
  });
}
