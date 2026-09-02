import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/workspace_scope.dart';
import 'package:hasim_cashier/core/pos/application/backup_service.dart';
import 'package:hasim_cashier/core/pos/application/catalog_admin_service.dart';
import 'package:hasim_cashier/core/pos/application/checkout_service.dart';
import 'package:hasim_cashier/core/pos/application/document_numbers.dart';
import 'package:hasim_cashier/core/pos/application/draft_cart_store.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/application/reports_service.dart';
import 'package:hasim_cashier/core/pos/application/return_service.dart';
import 'package:hasim_cashier/core/pos/application/shift_service.dart';
import 'package:hasim_cashier/core/pos/application/stock_engine.dart';
import 'package:hasim_cashier/core/pos/domain/pricing_service.dart';
import 'package:hasim_cashier/core/api/network_guard.dart';
import 'package:hasim_cashier/core/pos/pos_errors.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/features/cart/cart_controller.dart';

const adminPerms = LocalAuthService.adminPermissions;

void main() {
  late AppDatabase db;
  late CatalogAdminService catalog;
  late CheckoutService checkout;
  late StockEngine stock;
  late DocumentNumberService numbers;
  late ShiftService shifts;
  late ReturnService returns;
  late LocalAuthService auth;

  setUp(() {
    db = AppDatabase.memory();
    catalog = CatalogAdminService(db);
    stock = StockEngine(db);
    numbers = DocumentNumberService(db);
    checkout = CheckoutService(db, stock, numbers, SyncQueueRepository(db));
    shifts = ShiftService(db);
    returns = ReturnService(db, stock);
    auth = LocalAuthService(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<({String storeId, String productId, String userId, String shiftId})>
      seedStore() async {
    final created = await auth.bootstrapStore(
      storeName: 'متجر اختبار',
      adminName: 'مدير',
      username: 'admin',
      pin: '1234',
      taxRate: 15,
    );
    final productId = await catalog.createProduct(
      workspaceId: PosMode.standaloneWorkspaceId,
      name: 'برجر',
      price: 10,
      cost: 4,
      taxRate: 15,
      stock: 10,
      trackStock: true,
      barcode: '123456',
      permissions: adminPerms,
    );
    final shiftId = await shifts.open(
      workspaceId: PosMode.standaloneWorkspaceId,
      userId: created.user.localId,
      openingCash: 100,
      permissions: adminPerms,
    );
    return (
      storeId: created.store.localId,
      productId: productId,
      userId: created.user.localId,
      shiftId: shiftId,
    );
  }

  test('pricing engine rounds tax after discount', () {
    const pricing = PricingService();
    final quote = pricing.quote(
      lines: const [
        PricedLine(
          productLocalId: 'p1',
          name: 'شاي',
          quantity: 2,
          unitPrice: 10,
        ),
      ],
      orderDiscountAmount: 5,
      fallbackTaxRate: 10,
    );
    expect(quote.subtotal, 20);
    expect(quote.orderDiscount, 5);
    expect(quote.taxAmount, 1.5);
    expect(quote.total, 16.5);
  });

  test(
    'standalone sale writes invoice tax payments and stock atomically',
    () async {
      final seed = await seedStore();
      final result = await checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: seed.storeId,
          permissions: adminPerms,
          clientReference: 'sale-1',
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: seed.productId,
              name: 'برجر',
              quantity: 3,
              unitPrice: 10,
              taxRate: 15,
              cost: 4,
            ),
          ],
          payments: const [
            PaymentTender(method: 'cash', amount: 34.5, tendered: 40),
          ],
          taxRate: 15,
          createdByUserId: seed.userId,
          shiftLocalId: seed.shiftId,
        ),
      );
      expect(result.invoiceNumber, 'INV-000001');
      expect(result.total, 34.5);
      expect(result.changeDue, 5.5);

      final order = await (db.select(
        db.localOrders,
      )..where((t) => t.localId.equals('sale-1'))).getSingle();
      expect(order.taxAmount, 450);
      expect(order.subtotal, 3000);
      expect(order.totalAmount, 3450);
      expect(order.paymentStatus, 'paid');

      final item = (await (db.select(
        db.localOrderItems,
      )..where((t) => t.orderLocalId.equals('sale-1'))).get()).single;
      expect(item.taxRate, 15);
      expect(item.taxAmount, 450);
      expect(item.name, 'برجر');

      final product = await (db.select(
        db.localProducts,
      )..where((t) => t.localId.equals(seed.productId))).getSingle();
      expect(product.stock, 7);

      final movement = (await db.select(db.localStockMovements).get()).single;
      expect(movement.beforeQuantity, 10);
      expect(movement.afterQuantity, 7);
      expect(movement.kind, 'sale');

      final queue = await db.select(db.syncQueueItems).get();
      expect(queue, isEmpty);
    },
  );

  test('double tap pay is idempotent', () async {
    final seed = await seedStore();
    final cmd = CheckoutCommand(
      workspaceId: PosMode.standaloneWorkspaceId,
      deviceId: 'dev-1',
      storeId: seed.storeId,
      permissions: adminPerms,
      clientReference: 'sale-dup',
      orderType: 'delivery',
      lines: [
        PricedLine(
          productLocalId: seed.productId,
          name: 'برجر',
          quantity: 1,
          unitPrice: 10,
          taxRate: 0,
        ),
      ],
      payments: const [PaymentTender(method: 'card', amount: 10)],
      shiftLocalId: seed.shiftId,
    );
    final a = await checkout.execute(cmd);
    final b = await checkout.execute(cmd);
    expect(a.invoiceLocalId, b.invoiceLocalId);
    expect(await db.select(db.localOrders).get(), hasLength(1));
    expect(await db.select(db.localInvoices).get(), hasLength(1));
  });

  test('insufficient stock blocks the whole sale', () async {
    final seed = await seedStore();
    expect(
      () => checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: seed.storeId,
          permissions: adminPerms,
          clientReference: 'sale-stock',
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: seed.productId,
              name: 'برجر',
              quantity: 99,
              unitPrice: 10,
            ),
          ],
          payments: const [PaymentTender(method: 'cash', amount: 990)],
          shiftLocalId: seed.shiftId,
        ),
      ),
      throwsA(isA<InsufficientStock>()),
    );
    expect(await db.select(db.localOrders).get(), isEmpty);
    final product = await (db.select(
      db.localProducts,
    )..where((t) => t.localId.equals(seed.productId))).getSingle();
    expect(product.stock, 10);
  });

  test('split payment cash+card and credit shortfall', () async {
    final seed = await seedStore();
    final result = await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-split',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 2,
            unitPrice: 25,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 20, tendered: 20),
          PaymentTender(method: 'card', amount: 30),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    expect(result.total, 50);
    final pays = await db.select(db.localPayments).get();
    expect(pays, hasLength(2));
    expect(pays.map((p) => p.method), containsAll(['cash', 'card']));
  });

  test('return restocks and records refund cash movement', () async {
    final seed = await seedStore();
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-ret',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 2,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 20, tendered: 20),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    final item = (await db.select(db.localOrderItems).get()).single;
    await returns.execute(
      workspaceId: PosMode.standaloneWorkspaceId,
      orderLocalId: 'sale-ret',
      lines: [ReturnLineInput(orderItemLocalId: item.localId, quantity: 1)],
      allowNegativeStock: true,
      shiftLocalId: seed.shiftId,
      permissions: adminPerms,
      createdByUserId: seed.userId,
      deviceId: 'dev-1',
    );
    final product = await (db.select(
      db.localProducts,
    )..where((t) => t.localId.equals(seed.productId))).getSingle();
    expect(product.stock, 9);
    expect(
      () => returns.execute(
        workspaceId: PosMode.standaloneWorkspaceId,
        orderLocalId: 'sale-ret',
        lines: [ReturnLineInput(orderItemLocalId: item.localId, quantity: 3)],
        allowNegativeStock: true,
        permissions: adminPerms,
      ),
      throwsA(isA<InvalidReturnQuantity>()),
    );
  });

  test('draft cart survives database reopen', () async {
    final dir = await Directory.systemTemp.createTemp('pos-draft');
    final file = File('${dir.path}/draft.sqlite');
    var fileDb = AppDatabase(NativeDatabase(file));
    final now = DateTime.now();
    await fileDb.into(fileDb.localProducts).insert(
      LocalProductsCompanion.insert(
        localId: 'p1',
        workspaceId: PosMode.standaloneWorkspaceId,
        name: 'شاي',
        updatedAt: now,
      ),
    );
    final store = DraftCartStore(fileDb);
    await store.save(
      workspaceId: PosMode.standaloneWorkspaceId,
      channel: 'takeaway',
      lines: const [
        PricedLine(
          productLocalId: 'p1',
          name: 'شاي',
          quantity: 2,
          unitPrice: 5,
        ),
      ],
    );
    await fileDb.close();
    fileDb = AppDatabase(NativeDatabase(file));
    final loaded = await DraftCartStore(
      fileDb,
    ).load(workspaceId: PosMode.standaloneWorkspaceId, channel: 'takeaway');
    expect(loaded, isNotNull);
    expect(loaded!.lines.single.quantity, 2);
    expect(loaded.lines.single.name, 'شاي');
    await fileDb.close();
    await dir.delete(recursive: true);
  });

  test('document numbers never use max(id)+1', () async {
    final now = DateTime.now();
    await db.into(db.localStores).insert(
      LocalStoresCompanion.insert(
        localId: 's1',
        workspaceId: PosMode.standaloneWorkspaceId,
        name: 'تسلسل',
        createdAt: now,
        updatedAt: now,
      ),
    );
    expect(await numbers.nextInvoiceNumber(storeId: 's1'), 'INV-000001');
    expect(await numbers.nextInvoiceNumber(storeId: 's1'), 'INV-000002');
    expect(await numbers.nextOrderNumber(storeId: 's1'), 'ORD-000001');
  });

  test('local pin auth and reports', () async {
    final seed = await seedStore();
    final user = await auth.login(
      workspaceId: PosMode.standaloneWorkspaceId,
      username: 'admin',
      pin: '1234',
    );
    expect(user.role, 'admin');
    expect(
      () => auth.login(
        workspaceId: PosMode.standaloneWorkspaceId,
        username: 'admin',
        pin: '0000',
      ),
      throwsA(isA<InvalidPin>()),
    );

    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-rep',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 10, tendered: 10),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    final report = await LocalReportsService(
      db,
    ).daily(workspaceId: PosMode.standaloneWorkspaceId, date: DateTime.now());
    expect(report['summary']['invoices_count'], 1);
    expect((report['payment_methods'] as List).first['total'], 10);
    expect((report['payment_methods'] as List).first['method'], 'cash');
  });

  test('backup export and restore keep invoices', () async {
    final seed = await seedStore();
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-bak',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 10, tendered: 10),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    final backup = BackupService(db);
    final dir = await Directory.systemTemp.createTemp('pos-bak');
    final file = await backup.exportBackup(
      workspaceId: PosMode.standaloneWorkspaceId,
      directory: dir,
      password: 'secret12',
      permissions: adminPerms,
    );
    final payload = jsonDecode(await file.readAsString()) as Map;
    expect(payload['format_version'], 3);
    expect(payload['ciphertext_b64'], isNotEmpty);
    expect(payload['checksum_sha256'], isNotEmpty);
    expect(payload.containsKey('tables'), isFalse);
    await backup.restore(
      Map<String, dynamic>.from(payload),
      confirmed: true,
      password: 'secret12',
      permissions: adminPerms,
    );
    expect(await db.select(db.localInvoices).get(), isNotEmpty);
  });

  test('shift expected cash formula', () async {
    final seed = await seedStore();
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-shift',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 10, tendered: 10),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    final closed = await shifts.close(
      workspaceId: PosMode.standaloneWorkspaceId,
      shiftId: seed.shiftId,
      actualCash: 109,
      permissions: adminPerms,
    );
    expect(closed['expected'], 110);
    expect(closed['difference'], -1);
  });

  test('barcode lookup is local', () async {
    await seedStore();
    final hit = await catalog.findByBarcode(
      workspaceId: PosMode.standaloneWorkspaceId,
      barcode: '123456',
    );
    expect(hit?['name'], 'برجر');
  });

  test('store existence makes offline POS ready without products', () async {
    expect(await db.isOfflinePosReady(PosMode.standaloneWorkspaceId), isFalse);
    expect(await db.isOfflinePosReady(PosMode.legacyCollidingWorkspaceId), isFalse);
    final created = await auth.bootstrapStore(
      storeName: 'فارغ',
      adminName: 'مدير',
      username: 'admin',
      pin: '1234',
    );
    expect(created.store.workspaceId, PosMode.standaloneWorkspaceId);
    expect(created.store.workspaceId, isNot(1));
    expect(await db.isOfflinePosReady(PosMode.standaloneWorkspaceId), isTrue);
    expect(await db.isOfflinePosReady(1), isFalse);
  });

  test('cart controller still totals after productLocalId rewrite', () {
    final cart = CartController();
    cart.setTaxRate(10);
    cart.addItem(
      productLocalId: '1',
      menuItemId: 1,
      name: 'شاي',
      unitPrice: 10,
    );
    cart.addItem(
      productLocalId: '1',
      menuItemId: 1,
      name: 'شاي',
      unitPrice: 10,
    );
    cart.setDiscount(5);
    expect(cart.state.subtotal, 20);
    expect(cart.state.taxAmount, 1.5);
    expect(cart.state.total, 16.5);
    expect(cart.state.channel, OrderChannel.takeaway);
  });

  test('money engine uses integer cents so 0.1+0.2 equals 0.3', () {
    expect(Money.fromCents(Money.toCents(0.1) + Money.toCents(0.2)), 0.3);
    const pricing = PricingService();
    final quote = pricing.quote(
      lines: const [
        PricedLine(
          productLocalId: 'a',
          name: 'A',
          quantity: 1,
          unitPrice: 0.1,
        ),
        PricedLine(
          productLocalId: 'b',
          name: 'B',
          quantity: 1,
          unitPrice: 0.2,
        ),
      ],
    );
    expect(quote.total, 0.3);
    expect(quote.totalCents, 30);
  });

  test('standalone core path never increments NetworkGuard', () async {
    NetworkGuard.reset();
    final seed = await seedStore();
    await auth.login(
      workspaceId: PosMode.standaloneWorkspaceId,
      username: 'admin',
      pin: '1234',
    );
    await catalog.findByBarcode(
      workspaceId: PosMode.standaloneWorkspaceId,
      barcode: '123456',
    );
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-iso',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 10, tendered: 10),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    expect(await db.select(db.localInvoices).get(), hasLength(1));
    final item = (await db.select(db.localOrderItems).get()).single;
    await returns.execute(
      workspaceId: PosMode.standaloneWorkspaceId,
      orderLocalId: 'sale-iso',
      lines: [ReturnLineInput(orderItemLocalId: item.localId, quantity: 1)],
      allowNegativeStock: false,
      shiftLocalId: seed.shiftId,
      permissions: adminPerms,
    );
    await LocalReportsService(
      db,
    ).daily(workspaceId: PosMode.standaloneWorkspaceId, date: DateTime.now());
    final dir = await Directory.systemTemp.createTemp('pos-iso');
    await BackupService(db).exportBackup(
      workspaceId: PosMode.standaloneWorkspaceId,
      directory: dir,
      password: 'secret12',
      permissions: adminPerms,
    );
    expect(NetworkGuard.attempts, 0);
    await dir.delete(recursive: true);
  });

  test('sale without open shift is rejected', () async {
    final seed = await seedStore();
    expect(
      () => checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: seed.storeId,
          permissions: adminPerms,
          clientReference: 'sale-noshift',
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: seed.productId,
              name: 'برجر',
              quantity: 1,
              unitPrice: 10,
            ),
          ],
          payments: const [PaymentTender(method: 'cash', amount: 10)],
        ),
      ),
      throwsA(isA<ShiftNotOpen>()),
    );
    expect(await db.select(db.localOrders).get(), isEmpty);
  });

  test('checkout faults after each write roll back the sale', () async {
    final seed = await seedStore();
    Future<void> assertEmpty(CheckoutFaultPoint point) async {
      final isolated = CheckoutService(
        db,
        stock,
        numbers,
        SyncQueueRepository(db),
        faultForTest: point,
      );
      await expectLater(
        isolated.execute(
          CheckoutCommand(
            workspaceId: PosMode.standaloneWorkspaceId,
            deviceId: 'dev-1',
            storeId: seed.storeId,
            permissions: adminPerms,
            clientReference: 'fault-$point',
            orderType: 'takeaway',
            lines: [
              PricedLine(
                productLocalId: seed.productId,
                name: 'برجر',
                quantity: 1,
                unitPrice: 10,
              ),
            ],
            payments: const [
              PaymentTender(method: 'cash', amount: 10, tendered: 10),
            ],
            shiftLocalId: seed.shiftId,
          ),
        ),
        throwsA(isA<DatabaseFailure>()),
      );
      expect(
        await (db.select(
          db.localOrders,
        )..where((t) => t.clientReference.equals('fault-$point'))).get(),
        isEmpty,
      );
      final product = await (db.select(
        db.localProducts,
      )..where((t) => t.localId.equals(seed.productId))).getSingle();
      expect(product.stock, 10);
    }

    await assertEmpty(CheckoutFaultPoint.afterOrder);
    await assertEmpty(CheckoutFaultPoint.afterStock);
    await assertEmpty(CheckoutFaultPoint.afterInvoice);
    await assertEmpty(CheckoutFaultPoint.afterPayment);
    await assertEmpty(CheckoutFaultPoint.afterCash);
  });

  test('cashier cannot refund discount catalog or backup', () async {
    final seed = await seedStore();
    final cashier = LocalAuthService.permissionsFor('cashier');
    expect(
      () => catalog.createProduct(
        workspaceId: PosMode.standaloneWorkspaceId,
        name: 'ممنوع',
        price: 1,
        permissions: cashier,
      ),
      throwsA(isA<Forbidden>()),
    );
    expect(
      () => checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: seed.storeId,
          permissions: cashier,
          clientReference: 'sale-disc',
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: seed.productId,
              name: 'برجر',
              quantity: 1,
              unitPrice: 10,
              itemDiscount: 1,
            ),
          ],
          payments: const [PaymentTender(method: 'cash', amount: 9)],
          shiftLocalId: seed.shiftId,
        ),
      ),
      throwsA(isA<Forbidden>()),
    );
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-perm',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 10, tendered: 10),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    final item = (await db.select(db.localOrderItems).get()).last;
    expect(
      () => returns.execute(
        workspaceId: PosMode.standaloneWorkspaceId,
        orderLocalId: 'sale-perm',
        lines: [ReturnLineInput(orderItemLocalId: item.localId, quantity: 1)],
        allowNegativeStock: false,
        permissions: cashier,
      ),
      throwsA(isA<Forbidden>()),
    );
    expect(
      () => BackupService(db).exportBackup(
        workspaceId: PosMode.standaloneWorkspaceId,
        permissions: cashier,
      ),
      throwsA(isA<Forbidden>()),
    );
  });

  test('return does not mutate paid invoice and nets in reports', () async {
    final seed = await seedStore();
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-imm',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 2,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 20, tendered: 20),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    final invoice = (await db.select(db.localInvoices).get()).single;
    expect(invoice.totalAmount, 2000);
    final item = (await db.select(db.localOrderItems).get()).single;
    await returns.execute(
      workspaceId: PosMode.standaloneWorkspaceId,
      orderLocalId: 'sale-imm',
      lines: [ReturnLineInput(orderItemLocalId: item.localId, quantity: 1)],
      allowNegativeStock: false,
      shiftLocalId: seed.shiftId,
      permissions: adminPerms,
    );
    final after = await (db.select(
      db.localInvoices,
    )..where((t) => t.localId.equals(invoice.localId))).getSingle();
    expect(after.totalAmount, 2000);
    expect(after.payloadJson, invoice.payloadJson);
    expect(
      () => returns.execute(
        workspaceId: PosMode.standaloneWorkspaceId,
        orderLocalId: 'sale-imm',
        lines: [ReturnLineInput(orderItemLocalId: item.localId, quantity: 2)],
        allowNegativeStock: false,
        permissions: adminPerms,
      ),
      throwsA(isA<InvalidReturnQuantity>()),
    );
    final report = await LocalReportsService(
      db,
    ).daily(workspaceId: PosMode.standaloneWorkspaceId, date: DateTime.now());
    expect(report['summary']['invoices_total'], 20);
    expect(report['summary']['return_amount'], 10);
    expect(report['summary']['net_sales'], 10);
  });

  test('sale return sale keeps stock ledger consistent', () async {
    final seed = await seedStore();
    Future<void> sell(String ref) {
      return checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: seed.storeId,
          permissions: adminPerms,
          clientReference: ref,
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: seed.productId,
              name: 'برجر',
              quantity: 2,
              unitPrice: 10,
            ),
          ],
          payments: const [
            PaymentTender(method: 'cash', amount: 20, tendered: 20),
          ],
          shiftLocalId: seed.shiftId,
        ),
      );
    }

    await sell('s1');
    var product = await (db.select(
      db.localProducts,
    )..where((t) => t.localId.equals(seed.productId))).getSingle();
    expect(product.stock, 8);
    final item = (await (db.select(
      db.localOrderItems,
    )..where((t) => t.orderLocalId.equals('s1'))).get()).single;
    await returns.execute(
      workspaceId: PosMode.standaloneWorkspaceId,
      orderLocalId: 's1',
      lines: [ReturnLineInput(orderItemLocalId: item.localId, quantity: 2)],
      allowNegativeStock: false,
      shiftLocalId: seed.shiftId,
      permissions: adminPerms,
    );
    product = await (db.select(
      db.localProducts,
    )..where((t) => t.localId.equals(seed.productId))).getSingle();
    expect(product.stock, 10);
    await sell('s2');
    product = await (db.select(
      db.localProducts,
    )..where((t) => t.localId.equals(seed.productId))).getSingle();
    expect(product.stock, 8);
    final moves = await (db.select(
      db.localStockMovements,
    )..where((t) => t.productLocalId.equals(seed.productId))).get();
    expect(moves, hasLength(3));
    for (final move in moves) {
      expect(move.afterQuantity, move.beforeQuantity! + (
        move.kind == 'sale' ? -move.quantity : move.quantity
      ));
    }
  });

  test('exact stock sells and negative stock is gated', () async {
    final seed = await seedStore();
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-exact',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 10,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 100, tendered: 100),
        ],
        shiftLocalId: seed.shiftId,
      ),
    );
    expect(
      () => checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: seed.storeId,
          permissions: adminPerms,
          clientReference: 'sale-over',
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: seed.productId,
              name: 'برجر',
              quantity: 1,
              unitPrice: 10,
            ),
          ],
          payments: const [PaymentTender(method: 'cash', amount: 10)],
          shiftLocalId: seed.shiftId,
        ),
      ),
      throwsA(isA<InsufficientStock>()),
    );
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-neg',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
        payments: const [PaymentTender(method: 'cash', amount: 10)],
        shiftLocalId: seed.shiftId,
        allowNegativeStock: true,
      ),
    );
    final product = await (db.select(
      db.localProducts,
    )..where((t) => t.localId.equals(seed.productId))).getSingle();
    expect(product.stock, -1);
  });

  test('pin is hashed never plaintext', () async {
    final created = await auth.bootstrapStore(
      storeName: 'ملح',
      adminName: 'مدير',
      username: 'hashadmin',
      pin: '1234',
    );
    expect(created.user.pinHash, isNot('1234'));
    expect(created.user.pinHash.contains('1234'), isFalse);
    expect(created.user.pinHash.startsWith('pbkdf2-sha256\$'), isTrue);
    expect(created.user.pinSalt, isNotEmpty);
  });

  test('legacy standalone workspace 1 remaps to reserved scope', () async {
    final now = DateTime.now();
    await db
        .into(db.localStores)
        .insert(
          LocalStoresCompanion.insert(
            localId: 'legacy-store',
            workspaceId: 1,
            name: 'قديم',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.localProducts).insert(
      LocalProductsCompanion.insert(
        localId: 'legacy-p',
        workspaceId: 1,
        name: 'شاي',
        updatedAt: now,
      ),
    );
    await db.remapLegacyStandaloneWorkspaceIfNeeded();
    final remapped = await (db.select(
      db.localStores,
    )..where((t) => t.localId.equals('legacy-store'))).getSingle();
    expect(remapped.workspaceId, PosMode.standaloneWorkspaceId);
    final product = await (db.select(
      db.localProducts,
    )..where((t) => t.localId.equals('legacy-p'))).getSingle();
    expect(product.workspaceId, PosMode.standaloneWorkspaceId);
  });

  test('second open shift returns the same active shift', () async {
    final seed = await seedStore();
    final again = await shifts.open(
      workspaceId: PosMode.standaloneWorkspaceId,
      userId: seed.userId,
      openingCash: 50,
      permissions: adminPerms,
    );
    expect(again, seed.shiftId);
    expect(
      () => shifts.close(
        workspaceId: PosMode.standaloneWorkspaceId,
        shiftId: seed.shiftId,
        actualCash: 100,
        permissions: LocalAuthService.permissionsFor('cashier'),
      ),
      throwsA(isA<Forbidden>()),
    );
  });

  test('draft cart is cleared inside checkout transaction', () async {
    final seed = await seedStore();
    final drafts = DraftCartStore(db);
    await drafts.save(
      workspaceId: PosMode.standaloneWorkspaceId,
      channel: 'takeaway',
      lines: [
        PricedLine(
          productLocalId: seed.productId,
          name: 'برجر',
          quantity: 1,
          unitPrice: 10,
        ),
      ],
    );
    await checkout.execute(
      CheckoutCommand(
        workspaceId: PosMode.standaloneWorkspaceId,
        deviceId: 'dev-1',
        storeId: seed.storeId,
        permissions: adminPerms,
        clientReference: 'sale-draft',
        orderType: 'takeaway',
        lines: [
          PricedLine(
            productLocalId: seed.productId,
            name: 'برجر',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
        payments: const [
          PaymentTender(method: 'cash', amount: 10, tendered: 10),
        ],
        shiftLocalId: seed.shiftId,
        clearDraftChannel: 'takeaway',
      ),
    );
    expect(
      await drafts.load(
        workspaceId: PosMode.standaloneWorkspaceId,
        channel: 'takeaway',
      ),
      isNull,
    );
  });
}
