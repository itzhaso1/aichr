import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/pos/application/checkout_service.dart';
import 'package:hasim_cashier/core/pos/application/document_numbers.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/application/reports_service.dart';
import 'package:hasim_cashier/core/pos/application/shift_service.dart';
import 'package:hasim_cashier/core/pos/application/stock_engine.dart';
import 'package:hasim_cashier/core/pos/domain/pricing_service.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';
import 'package:hasim_cashier/core/repositories/local_finance_repository.dart';
import 'package:hasim_cashier/core/repositories/orders_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/repositories/tables_repository.dart';
import 'package:hasim_cashier/core/util/json_numbers.dart';
import 'package:hasim_cashier/core/util/occupied_duration.dart';

void main() {
  late AppDatabase db;
  late SyncQueueRepository queue;
  late TablesRepository tables;
  late OrdersRepository orders;
  late LocalReportsService reports;
  late LocalFinanceRepository finance;

  setUp(() {
    db = AppDatabase.memory();
    queue = SyncQueueRepository(db);
    tables = TablesRepository(db, queue);
    orders = OrdersRepository(db, queue);
    reports = LocalReportsService(db);
    finance = LocalFinanceRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedTable({
    int workspaceId = 1,
    int tableId = 4,
    String localId = 'uuid-table-4',
  }) async {
    final now = DateTime.now();
    await db
        .into(db.localTables)
        .insert(
          LocalTablesCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            serverId: Value(tableId),
            name: 'طاولة $tableId',
            status: const Value('available'),
            payloadJson: Value(
              jsonEncode({
                'id': tableId,
                'name': 'طاولة $tableId',
                'status': 'available',
              }),
            ),
            updatedAt: now,
          ),
        );
  }

  test('occupied duration formats as HH:MM:SS', () {
    final opened = DateTime(2026, 1, 1, 12, 0, 0);
    final now = DateTime(2026, 1, 1, 12, 15, 32);
    expect(formatOccupiedDuration(opened, now), '00:15:32');
    expect(parseOpenedAt('2026-01-01T12:00:00.000Z'), isNotNull);
  });

  test(
    'cashier occupyFromCheckout marks the table busy with opened_at',
    () async {
      await seedTable();
      final occupied = await tables.occupyFromCheckout(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableLocalId: 'uuid-table-4',
        tableServerId: 4,
        invoiceLocalId: 'inv-1',
        invoiceNumber: 'INV-1',
        total: 23,
        items: [
          {
            'item_name': 'شاي',
            'quantity': 1,
            'unit_price': 23,
            'total_amount': 23,
          },
        ],
      );
      expect(occupied?['status'], 'occupied');
      expect(occupied?['session_open'], isTrue);
      expect(occupied?['session_client_id'], isNotEmpty);
      expect(occupied?['opened_at'], isNotEmpty);
      expect(asDoubleOr(occupied?['total']), 23);

      final board = await tables.listTables(1);
      expect(board.single['status'], 'occupied');
      expect(board.single['opened_at'], isNotEmpty);
    },
  );

  test(
    'closing an already-invoiced occupied table does not write a second invoice',
    () async {
      await seedTable();
      final now = DateTime.now();
      await db
          .into(db.localInvoices)
          .insert(
            LocalInvoicesCompanion.insert(
              localId: 'inv-cashier',
              workspaceId: 1,
              deviceId: 'dev-1',
              invoiceNumber: const Value('INV-CASHIER'),
              totalAmount: const Value(2300),
              createdAt: now,
            ),
          );
      await tables.occupyFromCheckout(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableServerId: 4,
        invoiceLocalId: 'inv-cashier',
        invoiceNumber: 'INV-CASHIER',
        total: 23,
      );

      final closed = await tables.closeSessionLocal(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableServerId: 4,
        paymentMethod: 'cash',
      );
      expect(closed['freed_only'], isTrue);
      expect(closed['invoice'], isNull);

      final table = await tables.getTable(1, 4);
      expect(table?['status'], 'available');
      expect(table?['opened_at'], isNull);

      final invoices = await finance.listInvoices(workspaceId: 1);
      expect(invoices, hasLength(1));
      expect(invoices.single['invoice_number'], 'INV-CASHIER');
    },
  );

  test(
    'checkout with a table writes one invoice and occupies the table',
    () async {
      final auth = LocalAuthService(db);
      final catalogShift = ShiftService(db);
      final created = await auth.bootstrapStore(
        storeName: 'متجر اختبار',
        adminName: 'مدير',
        username: 'admin',
        pin: '1234',
        taxRate: 0,
      );
      final ws = PosMode.standaloneWorkspaceId;
      await seedTable(workspaceId: ws, tableId: 7, localId: 'table-7');
      await db
          .into(db.localProducts)
          .insert(
            LocalProductsCompanion.insert(
              localId: 'prod-tea',
              workspaceId: ws,
              name: 'شاي',
              price: const Value(1000),
              updatedAt: DateTime.now(),
            ),
          );
      final shiftId = await catalogShift.open(
        workspaceId: ws,
        userId: created.user.localId,
        openingCash: 100,
        permissions: LocalAuthService.adminPermissions,
      );
      final checkout = CheckoutService(
        db,
        StockEngine(db),
        DocumentNumberService(db),
        queue,
        tables: tables,
      );
      final result = await checkout.execute(
        CheckoutCommand(
          workspaceId: ws,
          deviceId: 'dev-1',
          storeId: created.store.localId,
          clientReference: 'sale-table-1',
          orderType: 'table',
          tableLocalId: 'table-7',
          tableServerId: 7,
          shiftLocalId: shiftId,
          permissions: LocalAuthService.adminPermissions,
          lines: const [
            PricedLine(
              productLocalId: 'prod-tea',
              name: 'شاي',
              quantity: 1,
              unitPrice: 10,
            ),
          ],
          payments: const [PaymentTender(method: 'cash', amount: 10)],
        ),
      );
      expect(result.invoiceNumber, isNotEmpty);

      final invoices = await finance.listInvoices(
        workspaceId: ws,
        fallbackAllWorkspaces: true,
      );
      expect(invoices, hasLength(1));
      expect(asDoubleOr(invoices.single['total_amount']), 10);
      expect(invoices.single['table'], isA<Map>());

      final table = await tables.getTable(ws, 7);
      expect(table?['status'], 'occupied');
      expect(table?['opened_at'], isNotEmpty);
      expect(table?['last_invoice_number'], result.invoiceNumber);

      final daily = await reports.daily(workspaceId: ws, date: DateTime.now());
      expect(daily['summary']['invoices_count'], 1);
      expect(asDoubleOr(daily['summary']['invoice_sales_total']), 10);
    },
  );

  test(
    'reports.daily includes a sale saved under another workspace id',
    () async {
      final now = DateTime.now();
      await db
          .into(db.localInvoices)
          .insert(
            LocalInvoicesCompanion.insert(
              localId: 'inv-other-ws',
              workspaceId: 42,
              deviceId: 'dev-1',
              invoiceNumber: const Value('INV-OTHER'),
              totalAmount: const Value(2500),
              createdAt: now,
            ),
          );
      final daily = await reports.daily(workspaceId: 900001, date: now);
      expect(daily['summary']['invoices_count'], 1);
      expect(asDoubleOr(daily['summary']['invoice_sales_total']), 25);
    },
  );

  test(
    'listInvoices fallback includes LOCAL invoices from another workspace',
    () async {
      final now = DateTime.now();
      await db
          .into(db.localInvoices)
          .insert(
            LocalInvoicesCompanion.insert(
              localId: 'inv-own',
              workspaceId: PosMode.standaloneWorkspaceId,
              deviceId: 'dev-1',
              invoiceNumber: const Value('INV-OWN'),
              totalAmount: const Value(1000),
              createdAt: now,
            ),
          );
      await db
          .into(db.localInvoices)
          .insert(
            LocalInvoicesCompanion.insert(
              localId: 'inv-local-uuid',
              workspaceId: 1,
              deviceId: 'dev-1',
              invoiceNumber: const Value(
                'LOCAL-67b8052b-adbf-4d7c-a2e1-c3c06454f78e',
              ),
              totalAmount: const Value(1500),
              createdAt: now,
            ),
          );
      final listed = await finance.listInvoices(
        workspaceId: PosMode.standaloneWorkspaceId,
        fallbackAllWorkspaces: true,
      );
      expect(
        listed.map((e) => e['invoice_number']),
        containsAll(['INV-OWN', 'LOCAL-67b8052b-adbf-4d7c-a2e1-c3c06454f78e']),
      );
    },
  );

  List<String> itemNamesOnTable(Map<String, dynamic>? table) {
    final names = <String>[];
    for (final order in asMapList(table?['orders'])) {
      expect(orderDisplayLabel(order), isNot('#null'));
      for (final item in asMapList(order['items'])) {
        final name = catalogItemName(item);
        expect(name, isNot('null'));
        names.add(name);
      }
    }
    return names;
  }

  test('occupy stores nested product names not a flat #null list', () async {
    await seedTable();
    final occupied = await tables.occupyFromCheckout(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableLocalId: 'uuid-table-4',
      tableServerId: 4,
      invoiceLocalId: 'inv-names',
      invoiceNumber: 'INV-NAMES',
      orderLocalId: 'ord-names',
      total: 15,
      items: [
        {
          'product_local_id': 'prod-burger',
          'item_name': 'Burger',
          'quantity': 2,
          'unit_price': 5,
          'total_amount': 10,
        },
        {
          'product_local_id': 'prod-cola',
          'item_name': 'Cola',
          'quantity': 1,
          'unit_price': 2,
          'total_amount': 2,
        },
        {
          'product_local_id': 'prod-fries',
          'item_name': 'Fries',
          'quantity': 1,
          'unit_price': 3,
          'total_amount': 3,
        },
      ],
    );
    expect(occupied?['status'], 'occupied');
    expect(occupied?['opened_at'], isNotEmpty);
    expect(itemNamesOnTable(occupied), ['Burger', 'Cola', 'Fries']);
    final orders = asMapList(occupied?['orders']);
    expect(orders, hasLength(1));
    expect(orders.single['order_number'], 'INV-NAMES');
  });

  test('closing then occupying again does not revive old products', () async {
    await seedTable();
    await tables.occupyFromCheckout(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableServerId: 4,
      invoiceLocalId: 'inv-old',
      invoiceNumber: 'INV-OLD',
      total: 10,
      items: [
        {
          'item_name': 'Burger',
          'quantity': 1,
          'unit_price': 10,
          'total_amount': 10,
        },
      ],
    );
    final closed = await tables.closeSessionLocal(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableServerId: 4,
    );
    expect(closed['freed_only'], isTrue);
    expect(closed['invoice'], isNull);
    final empty = await tables.getTable(1, 4);
    expect(empty?['status'], 'available');
    expect(itemNamesOnTable(empty), isEmpty);
    expect(asMapList(empty?['last_sale_items']), isEmpty);

    final again = await tables.occupyFromCheckout(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableServerId: 4,
      invoiceLocalId: 'inv-new',
      invoiceNumber: 'INV-NEW',
      total: 4,
      items: [
        {
          'item_name': 'Cola',
          'quantity': 2,
          'unit_price': 2,
          'total_amount': 4,
        },
      ],
    );
    expect(itemNamesOnTable(again), ['Cola']);
    expect(itemNamesOnTable(again), isNot(contains('Burger')));
  });

  test('getTable wraps legacy flat occupy lines so names render', () async {
    await seedTable();
    final now = DateTime.now();
    await (db.update(
      db.localTables,
    )..where((t) => t.localId.equals('uuid-table-4'))).write(
      LocalTablesCompanion(
        status: const Value('occupied'),
        payloadJson: Value(
          jsonEncode({
            'id': 4,
            'status': 'occupied',
            'session_open': true,
            'session_client_id': 'sess-legacy',
            'opened_at': now.toUtc().toIso8601String(),
            'orders': [
              {
                'item_name': 'شاي',
                'quantity': 1,
                'unit_price': 5,
                'total_amount': 5,
              },
              {
                'name': 'كولا',
                'quantity': 1,
                'unit_price': 2,
                'total_amount': 2,
              },
            ],
          }),
        ),
        updatedAt: Value(now),
      ),
    );
    final detail = await tables.getTable(1, 4);
    expect(detail?['status'], 'occupied');
    expect(itemNamesOnTable(detail), ['شاي', 'كولا']);
    expect(
      orderDisplayLabel(asMapList(detail?['orders']).first),
      isNot('#null'),
    );
  });

  test(
    'new cashier occupy cancels leftover unpaid lines from an old session',
    () async {
      await seedTable();
      final now = DateTime.now();
      await db
          .into(db.localOrders)
          .insert(
            LocalOrdersCompanion.insert(
              localId: 'old-unpaid',
              workspaceId: 1,
              deviceId: 'dev-1',
              clientReference: 'old-unpaid',
              orderType: 'table',
              tableServerId: const Value(4),
              tableLocalId: const Value('uuid-table-4'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.localOrderItems)
          .insert(
            LocalOrderItemsCompanion.insert(
              localId: 'old-unpaid-item',
              workspaceId: 1,
              orderLocalId: 'old-unpaid',
              name: 'طلب قديم',
              quantity: 1,
              unitPrice: 900,
              totalAmount: 900,
              updatedAt: now,
            ),
          );
      final occupied = await tables.occupyFromCheckout(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableServerId: 4,
        invoiceLocalId: 'inv-fresh',
        invoiceNumber: 'INV-FRESH',
        total: 5,
        items: [
          {
            'item_name': 'Burger',
            'quantity': 1,
            'unit_price': 5,
            'total_amount': 5,
          },
        ],
      );
      expect(itemNamesOnTable(occupied), ['Burger']);
      expect(itemNamesOnTable(occupied), isNot(contains('طلب قديم')));
      final leftover = await (db.select(
        db.localOrders,
      )..where((t) => t.localId.equals('old-unpaid'))).getSingle();
      expect(leftover.posStatus, 'cancelled');
    },
  );

  test('checkout invoice lines keep product names used on the table', () async {
    final auth = LocalAuthService(db);
    final catalogShift = ShiftService(db);
    final created = await auth.bootstrapStore(
      storeName: 'متجر أسماء',
      adminName: 'مدير',
      username: 'admin2',
      pin: '1234',
      taxRate: 0,
    );
    final ws = PosMode.standaloneWorkspaceId;
    await seedTable(workspaceId: ws, tableId: 8, localId: 'table-8');
    await db
        .into(db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            localId: 'prod-burger',
            workspaceId: ws,
            name: 'Burger',
            price: const Value(500),
            updatedAt: DateTime.now(),
          ),
        );
    await db
        .into(db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            localId: 'prod-cola',
            workspaceId: ws,
            name: 'Cola',
            price: const Value(200),
            updatedAt: DateTime.now(),
          ),
        );
    await db
        .into(db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            localId: 'prod-fries',
            workspaceId: ws,
            name: 'Fries',
            price: const Value(300),
            updatedAt: DateTime.now(),
          ),
        );
    final shiftId = await catalogShift.open(
      workspaceId: ws,
      userId: created.user.localId,
      openingCash: 100,
      permissions: LocalAuthService.adminPermissions,
    );
    final checkout = CheckoutService(
      db,
      StockEngine(db),
      DocumentNumberService(db),
      queue,
      tables: tables,
    );
    await checkout.execute(
      CheckoutCommand(
        workspaceId: ws,
        deviceId: 'dev-1',
        storeId: created.store.localId,
        clientReference: 'sale-names-1',
        orderType: 'table',
        tableLocalId: 'table-8',
        tableServerId: 8,
        shiftLocalId: shiftId,
        permissions: LocalAuthService.adminPermissions,
        lines: const [
          PricedLine(
            productLocalId: 'prod-burger',
            name: 'Burger',
            quantity: 2,
            unitPrice: 5,
          ),
          PricedLine(
            productLocalId: 'prod-cola',
            name: 'Cola',
            quantity: 1,
            unitPrice: 2,
          ),
          PricedLine(
            productLocalId: 'prod-fries',
            name: 'Fries',
            quantity: 1,
            unitPrice: 3,
          ),
        ],
        payments: const [PaymentTender(method: 'cash', amount: 15)],
      ),
    );
    final table = await tables.getTable(ws, 8);
    expect(itemNamesOnTable(table), ['Burger', 'Cola', 'Fries']);
    final invoices = await finance.listInvoices(
      workspaceId: ws,
      fallbackAllWorkspaces: true,
    );
    final latest = invoices.firstWhere(
      (row) => asDoubleOr(row['total_amount']) == 15,
    );
    final invoiceNames = [
      for (final item in asMapList(latest['items'])) catalogItemName(item),
    ];
    expect(invoiceNames, ['Burger', 'Cola', 'Fries']);
    final daily = await reports.daily(workspaceId: ws, date: DateTime.now());
    expect(
      asIntOr(daily['summary']['invoices_count']),
      greaterThanOrEqualTo(1),
    );
  });

  test(
    'adding a table order appends cashier occupy items instead of replacing',
    () async {
      await seedTable();
      await tables.occupyFromCheckout(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableLocalId: 'uuid-table-4',
        tableServerId: 4,
        invoiceLocalId: 'inv-cashier-1',
        invoiceNumber: 'INV-CASHIER-1',
        orderLocalId: 'ord-cashier-1',
        total: 24,
        items: [
          {
            'item_name': 'برجر',
            'quantity': 2,
            'unit_price': 8,
            'total_amount': 16,
          },
          {
            'item_name': 'عصير',
            'quantity': 2,
            'unit_price': 4,
            'total_amount': 8,
          },
        ],
      );
      expect(itemNamesOnTable(await tables.getTable(1, 4)), ['برجر', 'عصير']);

      await orders.createTableOrder(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableId: 4,
        clientReference: 'ord-table-add-1',
        items: [
          {
            'name': 'بيتزا',
            'quantity': 1,
            'unit_price': 12,
            'total_amount': 12,
          },
          {'name': 'ماء', 'quantity': 2, 'unit_price': 1, 'total_amount': 2},
        ],
      );

      final afterFirstAdd = await tables.getTable(1, 4);
      expect(
        itemNamesOnTable(afterFirstAdd),
        containsAll(['برجر', 'عصير', 'بيتزا', 'ماء']),
      );
      expect(asMapList(afterFirstAdd?['orders']), hasLength(2));

      final afterReopen = await tables.getTable(1, 4);
      expect(
        itemNamesOnTable(afterReopen),
        containsAll(['برجر', 'عصير', 'بيتزا', 'ماء']),
      );

      await orders.createTableOrder(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableId: 4,
        clientReference: 'ord-table-add-2',
        items: [
          {'name': 'سلطة', 'quantity': 1, 'unit_price': 6, 'total_amount': 6},
        ],
      );
      final afterSecondAdd = await tables.getTable(1, 4);
      expect(
        itemNamesOnTable(afterSecondAdd),
        containsAll(['برجر', 'عصير', 'بيتزا', 'ماء', 'سلطة']),
      );
      expect(asMapList(afterSecondAdd?['orders']), hasLength(3));
      expect(
        itemNamesOnTable(await tables.getTable(1, 4)),
        containsAll(['برجر', 'عصير', 'بيتزا', 'ماء', 'سلطة']),
      );
    },
  );

  test(
    'second cashier occupy then table add keeps every session order',
    () async {
      await seedTable();
      await tables.occupyFromCheckout(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableServerId: 4,
        invoiceLocalId: 'inv-a',
        invoiceNumber: 'INV-A',
        orderLocalId: 'ord-a',
        total: 10,
        items: [
          {
            'item_name': 'برجر',
            'quantity': 1,
            'unit_price': 10,
            'total_amount': 10,
          },
        ],
      );
      await tables.occupyFromCheckout(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableServerId: 4,
        invoiceLocalId: 'inv-b',
        invoiceNumber: 'INV-B',
        orderLocalId: 'ord-b',
        total: 8,
        items: [
          {
            'item_name': 'عصير',
            'quantity': 2,
            'unit_price': 4,
            'total_amount': 8,
          },
        ],
      );
      await orders.createTableOrder(
        workspaceId: 1,
        deviceId: 'dev-1',
        tableId: 4,
        clientReference: 'ord-c',
        items: [
          {
            'name': 'بيتزا',
            'quantity': 1,
            'unit_price': 12,
            'total_amount': 12,
          },
        ],
      );
      expect(
        itemNamesOnTable(await tables.getTable(1, 4)),
        containsAll(['برجر', 'عصير', 'بيتزا']),
      );
    },
  );
}
