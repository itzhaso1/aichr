import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/pos/application/reports_service.dart';
import 'package:hasim_cashier/core/repositories/local_finance_repository.dart';
import 'package:hasim_cashier/core/repositories/orders_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/util/json_numbers.dart';
import 'package:hasim_cashier/core/repositories/tables_repository.dart';

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

  Future<void> seedUuidTable({
    int workspaceId = 1,
    int tableId = 4,
    String localId = 'uuid-table-4',
  }) async {
    final now = DateTime.now();
    await db.into(db.localTables).insert(
          LocalTablesCompanion.insert(
            localId: localId,
            workspaceId: workspaceId,
            serverId: Value(tableId),
            name: 'طاولة $tableId',
            status: const Value('available'),
            payloadJson: Value(jsonEncode({
              'id': tableId,
              'name': 'طاولة $tableId',
              'status': 'available',
            })),
            updatedAt: now,
          ),
        );
  }

  test('table order stays on the table without a sync badge', () async {
    await seedUuidTable();
    await tables.openSessionLocal(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableServerId: 4,
    );
    final created = await orders.createTableOrder(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableId: 4,
      clientReference: 'ord-table-1',
      items: [
        {
          'pos_menu_item_id': 11,
          'name': 'شاي',
          'quantity': 2,
          'unit_price': 5,
          'total_amount': 10,
        },
      ],
    );
    expect(created['sync_label'], isNull);
    expect(created['total_amount'], 10);

    final open = await orders.listOpenForTable(workspaceId: 1, tableId: 4);
    expect(open, hasLength(1));
    expect(open.single['sync_label'], isNull);
    expect(open.single['items'], isNotEmpty);

    final detail = await tables.getTable(1, 4);
    expect(detail?['status'], 'occupied');
    expect(detail?['open_orders_count'], 1);
    final payloadOrders = detail?['orders'];
    expect(payloadOrders, isA<List>());
    expect((payloadOrders as List), isNotEmpty);
  });

  test('closing a table writes a local invoice that reports can load', () async {
    await seedUuidTable();
    await tables.openSessionLocal(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableServerId: 4,
    );
    await orders.createTableOrder(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableId: 4,
      clientReference: 'ord-close-1',
      items: [
        {
          'pos_menu_item_id': 11,
          'name': 'شاي',
          'quantity': 2,
          'unit_price': 7.5,
          'total_amount': 15,
        },
      ],
    );

    final closed = await tables.closeSessionLocal(
      workspaceId: 1,
      deviceId: 'dev-1',
      tableServerId: 4,
      paymentMethod: 'cash',
    );
    expect(closed['invoice'], isA<Map>());
    expect(closed['invoice']['total_amount'], 15);

    final table = await tables.getTable(1, 4);
    expect(table?['status'], 'available');
    final stillOpen = await orders.listOpenForTable(workspaceId: 1, tableId: 4);
    expect(stillOpen, isEmpty);

    final invoices = await finance.listInvoices(
      workspaceId: 1,
      onDate: DateTime.now(),
    );
    expect(invoices, hasLength(1));
    expect(asDoubleOr(invoices.single['total_amount']), 15);
    expect(invoices.single['items'], isNotEmpty);

    final listedWithoutDate = await finance.listInvoices(
      workspaceId: 1,
      fallbackAllWorkspaces: true,
    );
    expect(listedWithoutDate, hasLength(1));

    final daily = await reports.daily(workspaceId: 1, date: DateTime.now());
    expect(daily['summary']['invoices_count'], 1);
    expect(asDoubleOr(daily['summary']['invoice_sales_total']), 15);
    expect((daily['invoices'] as List), isNotEmpty);
  });

  test('reports.daily completes with an empty workspace', () async {
    final daily = await reports
        .daily(workspaceId: 1, date: DateTime.now())
        .timeout(const Duration(seconds: 2));
    expect(daily['summary']['invoices_count'], 0);
    expect(daily['source'], 'local_sqlite');
  });

  test('offline invoices tab can find a sale saved under another workspace id',
      () async {
    final now = DateTime.now();
    await db.into(db.localInvoices).insert(
          LocalInvoicesCompanion.insert(
            localId: 'inv-other-ws',
            workspaceId: 42,
            deviceId: 'dev-1',
            invoiceNumber: const Value('INV-OTHER'),
            totalAmount: const Value(2500),
            createdAt: now,
          ),
        );
    final found = await finance.listInvoices(
      workspaceId: 900001,
      fallbackAllWorkspaces: true,
    );
    expect(found, hasLength(1));
    expect(found.single['invoice_number'], 'INV-OTHER');
  });
}

