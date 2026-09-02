import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/workspace_scope.dart';
import 'package:hasim_cashier/core/network/link_policy.dart';
import 'package:hasim_cashier/core/repositories/orders_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/sync/sync_engine_v2.dart';
import 'package:hasim_cashier/core/widgets/hasim_widgets.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
  });

  test('backoff schedule is 2, 5, 15, 30 then capped', () {
    expect(SyncQueueRepository.backoffSecondsForAttempt(1), 2);
    expect(SyncQueueRepository.backoffSecondsForAttempt(2), 5);
    expect(SyncQueueRepository.backoffSecondsForAttempt(3), 15);
    expect(SyncQueueRepository.backoffSecondsForAttempt(4), 30);
    expect(SyncQueueRepository.backoffSecondsForAttempt(8), 300);
  });

  test('batch push is idempotent and records last_push_at', () async {
    final queue = SyncQueueRepository(db);
    final now = DateTime.now();
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'batch-ord',
            workspaceId: 1,
            deviceId: 'POS-001',
            clientReference: 'batch-ord',
            orderType: 'takeaway',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await queue.enqueue(
      workspaceId: 1,
      deviceId: 'POS-001',
      entityType: 'order',
      entityId: 'batch-ord',
      operation: 'create',
      payload: {
        'order_type': 'takeaway',
        'client_reference': 'batch-ord',
        'items': [
          {'pos_menu_item_id': 10, 'quantity': 1},
        ],
      },
      clientReference: 'batch-ord',
      operationUuid: 'op-batch-1',
    );

    var posts = 0;
    final engine = SyncEngineV2(
      db,
      queue,
      postPushBatch: (body) async {
        posts++;
        expect(body['device_id'], 'POS-001');
        final ops = body['operations'] as List;
        expect(ops, hasLength(1));
        expect(ops.first['id'], 'op-batch-1');
        expect(ops.first['type'], 'order.created');
        return {
          'success': true,
          'accepted': [
            {
              'id': 'op-batch-1',
              'status': posts == 1 ? 'applied' : 'duplicate',
              'entity_id': 44,
              'result': {'id': 44},
            },
          ],
          'failed': const [],
          'server_cursor': 9,
        };
      },
      fetchChanges: (since, limit) async => {
        'cursor': since,
        'server_cursor': 9,
        'has_more': false,
        'changes': const [],
      },
    );

    final first = await engine.pushPending(workspaceId: 1);
    expect(first.synced, 1);
    expect(posts, 1);
    final order = await (db.select(db.localOrders)
          ..where((t) => t.localId.equals('batch-ord')))
        .getSingle();
    expect(order.serverId, 44);
    expect(order.syncStatus, 'synced');

    final second = await engine.pushPending(workspaceId: 1);
    expect(second.synced, 0);
    expect(posts, 1);
    expect(await db.readMeta(1, SyncMetaKeys.lastPushAt), isNotNull);
  });

  test('sale writes local stock movement without queueing stock.movement',
      () async {
    final queue = SyncQueueRepository(db);
    final orders = OrdersRepository(db, queue);
    await db.into(db.localProducts).insert(
          LocalProductsCompanion.insert(
            localId: 'w1_prod_10',
            workspaceId: 1,
            serverId: const Value(10),
            name: 'شاي',
            stock: const Value(8),
            updatedAt: DateTime.now(),
          ),
        );
    await orders.createTakeawayOrder(
      workspaceId: 1,
      deviceId: 'POS-001',
      clientReference: 'sale-1',
      items: [
        {
          'pos_menu_item_id': 10,
          'name': 'شاي',
          'quantity': 2,
          'unit_price': 5,
          'total_amount': 10,
        },
      ],
    );
    final movements = await db.select(db.localStockMovements).get();
    expect(movements, hasLength(1));
    expect(movements.single.kind, 'sale');
    expect(movements.single.syncStatus, 'local');
    final product = await (db.select(db.localProducts)
          ..where((t) => t.serverId.equals(10)))
        .getSingle();
    expect(product.stock, 6);
    final queued = await queue.pendingForWorkspace(1);
    expect(queued.every((r) => r.entityType != 'stock'), isTrue);
  });

  testWidgets('connection banner always shows online status', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionBanner(
            link: CashierLink.online,
            lastSyncAt: null,
          ),
        ),
      ),
    );
    expect(find.textContaining('متصل'), findsOneWidget);
    expect(find.textContaining('لم تتم بعد'), findsOneWidget);
  });
}
