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
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/repositories/tables_repository.dart';
import 'package:hasim_cashier/core/util/json_numbers.dart';
import 'package:hasim_cashier/core/util/occupied_duration.dart';

void main() {
  late AppDatabase db;
  late SyncQueueRepository queue;
  late TablesRepository tables;
  late LocalReportsService reports;
  late LocalFinanceRepository finance;

  setUp(() {
    db = AppDatabase.memory();
    queue = SyncQueueRepository(db);
    tables = TablesRepository(db, queue);
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

  test('occupied duration formats as HH:MM:SS', () {
    final opened = DateTime(2026, 1, 1, 12, 0, 0);
    final now = DateTime(2026, 1, 1, 12, 15, 32);
    expect(formatOccupiedDuration(opened, now), '00:15:32');
    expect(parseOpenedAt('2026-01-01T12:00:00.000Z'), isNotNull);
  });

  test('cashier occupyFromCheckout marks the table busy with opened_at',
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
  });

  test('closing an already-invoiced occupied table does not write a second invoice',
      () async {
    await seedTable();
    final now = DateTime.now();
    await db.into(db.localInvoices).insert(
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
  });

  test('checkout with a table writes one invoice and occupies the table',
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
    await db.into(db.localProducts).insert(
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
  });

  test('reports.daily includes a sale saved under another workspace id',
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
    final daily = await reports.daily(
      workspaceId: 900001,
      date: now,
    );
    expect(daily['summary']['invoices_count'], 1);
    expect(asDoubleOr(daily['summary']['invoice_sales_total']), 25);
  });
}
