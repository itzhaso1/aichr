import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/workspace_scope.dart';
import 'package:hasim_cashier/core/repositories/customers_repository.dart';
import 'package:hasim_cashier/core/repositories/orders_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_conflict_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/sync/sync_engine_v2.dart';
import 'package:hasim_cashier/core/sync/sync_pull_applier.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

/// Simulates the Definition-of-Done offline → restart → sync scenario.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pos_e2e_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test(
    'E2E sim: initial cursor → offline create/update → restart → push/pull reconcile no duplicates',
    () async {
      final dbFile = File(p.join(tmp.path, 'pos.sqlite'));
      var db = AppDatabase.file(dbFile);
      final queue = SyncQueueRepository(db);
      final orders = OrdersRepository(db, queue);
      final customers = CustomersRepository(db, queue);
      final conflicts = SyncConflictRepository(db);
      final applier = SyncPullApplier(db, conflicts: conflicts);

      // Day 1: Initial Sync complete + cursor anchored.
      await db.markInitialSyncCompleted(1, deviceId: 'dev-a');
      await db.writeCursor(1, '1000', deviceId: 'dev-a');
      await applier.applyBatch(
        workspaceId: 1,
        fromCursor: 1000,
        responseCursor: 1000,
        changes: const [],
        deviceId: 'dev-a',
      );
      expect(await db.readCursor(1), '1000');

      // Internet OFF — create + modify + customer.
      final o1 = await orders.createTableOrder(
        workspaceId: 1,
        deviceId: 'dev-a',
        tableId: 7,
        clientReference: 'e2e-order-1',
        items: [
          {
            'pos_menu_item_id': 11,
            'name': 'شاي',
            'quantity': 1,
            'unit_price': 5,
            'total_amount': 5,
          },
        ],
      );
      await orders.updateLocalOrder(
        workspaceId: 1,
        localId: 'e2e-order-1',
        items: [
          {
            'pos_menu_item_id': 11,
            'name': 'شاي',
            'quantity': 3,
            'unit_price': 5,
            'total_amount': 15,
          },
        ],
        notes: 'مضاعف',
      );
      await orders.createTakeawayOrder(
        workspaceId: 1,
        deviceId: 'dev-a',
        clientReference: 'e2e-take-1',
        items: [
          {
            'pos_menu_item_id': 12,
            'name': 'قهوة',
            'quantity': 2,
            'unit_price': 8,
            'total_amount': 16,
          },
        ],
      );
      await customers.createOffline(
        workspaceId: 1,
        deviceId: 'dev-a',
        name: 'عميل E2E',
        phone: '0501111222',
        clientReference: 'e2e-cust-1',
      );

      expect(o1['client_reference'], 'e2e-order-1');
      expect((await queue.pendingForWorkspace(1)).length, greaterThanOrEqualTo(3));

      // Close app / reopen — same file, new connection.
      await db.close();
      db = AppDatabase.file(dbFile);
      final queue2 = SyncQueueRepository(db);
      final orders2 = OrdersRepository(db, queue2);
      final conflicts2 = SyncConflictRepository(db);

      final afterRestart = await orders2.listOrdersForTable(
        workspaceId: 1,
        tableId: 7,
      );
      expect(afterRestart.length, 1);
      expect(afterRestart.first['client_reference'], 'e2e-order-1');
      expect(afterRestart.first['items'], hasLength(1));
      expect(afterRestart.first['items'].first['quantity'], 3);
      expect(await db.readCursor(1), '1000');

      // Internet ON — push then pull with server echo + catalog change.
      var createPosts = 0;
      final engine = SyncEngineV2(
        db,
        queue2,
        postOrder: (payload, key) async {
          createPosts++;
          expect(payload['client_reference'], key);
          return {
            'id': key == 'e2e-order-1' ? 901 : 902,
            'order_number': key == 'e2e-order-1' ? 'T-901' : 'T-902',
          };
        },
        fetchChanges: (since, limit) async {
          expect(since, 1000);
          return {
            'cursor': 1003,
            'server_cursor': 1003,
            'has_more': false,
            'changes': [
              {
                'version': 1001,
                'entity': 'order',
                'operation': 'create',
                'id': 901,
                'origin_device_id': 'dev-a',
                'data': {
                  'id': 901,
                  'client_reference': 'e2e-order-1',
                  'order_type': 'table',
                  'dining_table_id': 7,
                  'total_amount': 15,
                  'pos_status': 'new',
                  'payment_status': 'unpaid',
                  'items': [
                    {
                      'id': 1,
                      'pos_menu_item_id': 11,
                      'product_name': 'شاي',
                      'quantity': 3,
                      'unit_price': 5,
                      'total_amount': 15,
                    },
                  ],
                },
              },
              {
                'version': 1002,
                'entity': 'product',
                'operation': 'update',
                'id': 11,
                'data': {
                  'id': 11,
                  'name': 'شاي محدّث',
                  'price': 6,
                  'is_active': true,
                },
              },
              {
                'version': 1003,
                'entity': 'customer',
                'operation': 'create',
                'id': 55,
                'origin_device_id': 'dev-a',
                'data': {
                  'id': 55,
                  'client_reference': 'e2e-cust-1',
                  'name': 'عميل E2E',
                  'phone': '0501111222',
                },
              },
            ],
          };
        },
      );

      // Customer push needs API — mark customer synced manually after simulating
      // order push via engine (customer entity handled when API present).
      final pendingBefore = await queue2.pendingForWorkspace(1);
      for (final row in pendingBefore.where((r) => r.entityType == 'customer')) {
        await queue2.markSynced(row.id);
      }

      final result = await engine.syncBidirectional(
        workspaceId: 1,
        deviceId: 'dev-a',
      );
      expect(result.pullFailed, isFalse);
      expect(createPosts, 2); // table + takeaway
      expect(result.cursor, 1003);

      final tableOrders = await orders2.listOrdersForTable(
        workspaceId: 1,
        tableId: 7,
      );
      expect(tableOrders.length, 1);
      expect(tableOrders.first['server_id'] ?? tableOrders.first['id'], 901);
      expect(tableOrders.first['sync_status'], 'synced');

      final allOrders = await db.select(db.localOrders).get();
      final refs = allOrders.map((o) => o.clientReference).toSet();
      expect(refs.contains('e2e-order-1'), isTrue);
      expect(refs.contains('e2e-take-1'), isTrue);
      expect(allOrders.where((o) => o.clientReference == 'e2e-order-1').length, 1);

      final products = await db.select(db.localProducts).get();
      expect(products.any((p) => p.name == 'شاي محدّث'), isTrue);
      expect(await db.readCursor(1), '1003');

      // Duplicate retry of same create must not create a second local row.
      await orders2.createTableOrder(
        workspaceId: 1,
        deviceId: 'dev-a',
        tableId: 7,
        clientReference: 'e2e-order-1',
        items: [
          {
            'pos_menu_item_id': 11,
            'name': 'شاي',
            'quantity': 1,
            'unit_price': 5,
            'total_amount': 5,
          },
        ],
      );
      expect(
        (await db.select(db.localOrders).get())
            .where((o) => o.clientReference == 'e2e-order-1')
            .length,
        1,
      );

      // Workspace isolation: workspace 2 cannot see these rows.
      expect(
        await orders2.listOrdersForTable(workspaceId: 2, tableId: 7),
        isEmpty,
      );
      expect(await conflicts2.openForWorkspace(1), isEmpty);

      await db.close();
    },
  );
}
