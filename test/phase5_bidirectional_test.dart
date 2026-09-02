import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/offline/conflict_strategy.dart';
import 'package:hasim_cashier/core/repositories/customers_repository.dart';
import 'package:hasim_cashier/core/repositories/orders_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_conflict_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/sync/sync_pull_applier.dart';

void main() {
  late AppDatabase db;
  late SyncQueueRepository queue;
  late OrdersRepository orders;
  late CustomersRepository customers;
  late SyncConflictRepository conflicts;

  setUp(() {
    db = AppDatabase.memory();
    queue = SyncQueueRepository(db);
    orders = OrdersRepository(db, queue);
    customers = CustomersRepository(db, queue);
    conflicts = SyncConflictRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('conflict strategy never LWW for orders/payments', () {
    expect(
      ConflictStrategy.forDomain('order'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('payment'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('invoice'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('product'),
      ConflictPolicy.serverWins,
    );
  });

  test('pull order reconciles by client_reference without duplicate', () async {
    await orders.createTableOrder(
      workspaceId: 1,
      deviceId: 'dev-a',
      tableId: 9,
      clientReference: 'ref-order-1',
      items: [
        {
          'pos_menu_item_id': 1,
          'name': 'شاي',
          'quantity': 1,
          'unit_price': 5,
          'total_amount': 5,
        },
      ],
    );

    final applier = SyncPullApplier(db, conflicts: conflicts);
    final cursor = await applier.applyBatch(
      workspaceId: 1,
      fromCursor: 0,
      responseCursor: 10,
      deviceId: 'dev-a',
      changes: [
        {
          'version': 10,
          'entity': 'order',
          'operation': 'create',
          'id': 501,
          'origin_device_id': 'dev-a',
          'data': {
            'id': 501,
            'client_reference': 'ref-order-1',
            'order_type': 'table',
            'dining_table_id': 9,
            'pos_status': 'new',
            'payment_status': 'unpaid',
            'subtotal': 5,
            'total_amount': 5,
            'items': [
              {
                'id': 1,
                'pos_menu_item_id': 1,
                'product_name': 'شاي',
                'quantity': 1,
                'unit_price': 5,
                'total_amount': 5,
              },
            ],
          },
        },
      ],
    );
    expect(cursor, 10);
    final rows = await db.select(db.localOrders).get();
    expect(rows.length, 1);
    expect(rows.first.serverId, 501);
    expect(rows.first.syncStatus, 'synced');
  });

  test('foreign device update while local pending records conflict', () async {
    await orders.createTableOrder(
      workspaceId: 1,
      deviceId: 'dev-a',
      tableId: 9,
      clientReference: 'ref-conflict',
      items: [
        {
          'pos_menu_item_id': 1,
          'name': 'شاي',
          'quantity': 1,
          'unit_price': 5,
          'total_amount': 5,
        },
      ],
    );

    final applier = SyncPullApplier(db, conflicts: conflicts);
    await applier.applyBatch(
      workspaceId: 1,
      fromCursor: 0,
      responseCursor: 20,
      deviceId: 'dev-a',
      changes: [
        {
          'version': 20,
          'entity': 'order',
          'operation': 'update',
          'id': 777,
          'origin_device_id': 'dev-b',
          'data': {
            'id': 777,
            'client_reference': 'ref-conflict',
            'order_type': 'table',
            'dining_table_id': 9,
            'notes': 'from B',
            'total_amount': 99,
            'items': const [],
          },
        },
      ],
    );

    final open = await conflicts.openForWorkspace(1);
    expect(open.length, 1);
    expect(open.first.entityType, 'order');
    expect(open.first.strategy, 'keep_local_pending');
    final local = await db.select(db.localOrders).getSingle();
    expect(local.syncStatus, 'pending');
    expect(local.totalAmount, 500);
  });

  test('customer offline create enqueues sync_queue', () async {
    final created = await customers.createOffline(
      workspaceId: 3,
      deviceId: 'dev-a',
      name: 'عميل',
      phone: '0500000000',
      clientReference: 'cust-1',
    );
    expect(created['local_id'], 'cust-1');
    final pending = await queue.pendingForWorkspace(3);
    expect(pending.where((r) => r.entityType == 'customer').length, 1);
  });

  test('takeaway local create is durable and workspace scoped', () async {
    await orders.createTakeawayOrder(
      workspaceId: 2,
      deviceId: 'dev-a',
      clientReference: 'take-1',
      items: [
        {
          'pos_menu_item_id': 4,
          'name': 'قهوة',
          'quantity': 2,
          'unit_price': 10,
          'total_amount': 20,
        },
      ],
    );
    final a = await db.select(db.localOrders).get();
    expect(a.length, 1);
    expect(a.first.orderType, 'takeaway');
    expect(a.first.workspaceId, 2);

    final other = await orders.listOrdersForTable(workspaceId: 99, tableId: 1);
    expect(other, isEmpty);
  });

  test('large pull batch advances cursor only after full apply', () async {
    final changes = <Map<String, dynamic>>[
      for (var i = 1; i <= 250; i++)
        {
          'version': i,
          'entity': 'product',
          'operation': 'create',
          'id': i,
          'data': {
            'id': i,
            'name': 'P$i',
            'price': i.toDouble(),
            'is_active': true,
          },
        },
    ];
    final applier = SyncPullApplier(db, conflicts: conflicts);
    final cursor = await applier.applyBatch(
      workspaceId: 1,
      fromCursor: 0,
      responseCursor: 250,
      changes: changes,
    );
    expect(cursor, 250);
    final products = await db.select(db.localProducts).get();
    expect(products.length, 250);
  });

  test('pull customer applies and scopes by workspace', () async {
    final applier = SyncPullApplier(db, conflicts: conflicts);
    await applier.applyBatch(
      workspaceId: 1,
      fromCursor: 0,
      responseCursor: 5,
      changes: [
        {
          'version': 5,
          'entity': 'customer',
          'operation': 'create',
          'id': 9,
          'data': {
            'id': 9,
            'client_reference': 'c-9',
            'name': 'نورة',
            'phone': '011',
          },
        },
      ],
    );
    final inA = await customers.list(workspaceId: 1);
    final inB = await customers.list(workspaceId: 2);
    expect(inA.length, 1);
    expect(inB, isEmpty);
  });

  test('payment pull upserts local cache without require_online conflict', () async {
    final applier = SyncPullApplier(db, conflicts: conflicts);
    await applier.applyBatch(
      workspaceId: 1,
      fromCursor: 0,
      responseCursor: 3,
      changes: [
        {
          'version': 3,
          'entity': 'payment',
          'operation': 'create',
          'id': 1,
          'data': {'id': 1, 'amount': 100, 'method': 'cash'},
        },
      ],
    );
    final payments = await db.select(db.localPayments).get();
    expect(payments, hasLength(1));
    expect(payments.single.serverId, 1);
    expect(payments.single.syncStatus, 'synced');
    expect(await conflicts.openForWorkspace(1), isEmpty);
  });
}
