import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/pos/application/backup_service.dart';
import 'package:hasim_cashier/core/pos/application/catalog_admin_service.dart';
import 'package:hasim_cashier/core/pos/application/checkout_service.dart';
import 'package:hasim_cashier/core/pos/application/document_numbers.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/application/pin_hasher.dart';
import 'package:hasim_cashier/core/pos/application/shift_service.dart';
import 'package:hasim_cashier/core/pos/application/stock_engine.dart';
import 'package:hasim_cashier/core/pos/domain/pricing_service.dart';
import 'package:hasim_cashier/core/pos/pos_errors.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';

import 'support/legacy_sqlite.dart';

const adminPerms = LocalAuthService.adminPermissions;

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
  });

  group('M1 foreign keys', () {
    test('order item without parent order is rejected', () async {
      expect(
        () => db.into(db.localOrderItems).insert(
          LocalOrderItemsCompanion.insert(
            localId: 'orphan-item',
            workspaceId: PosMode.standaloneWorkspaceId,
            orderLocalId: 'missing-order',
            name: 'شاي',
            quantity: 1,
            unitPrice: 100,
            totalAmount: 100,
            updatedAt: DateTime.now(),
          ),
        ),
        throwsA(isA<Object>()),
      );
    });

    test('deleting an order cascades items when no invoice exists', () async {
      final now = DateTime.now();
      await db.into(db.localOrders).insert(
        LocalOrdersCompanion.insert(
          localId: 'ord-c',
          workspaceId: 1,
          deviceId: 'dev-1',
          clientReference: 'ord-c',
          orderType: 'takeaway',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.into(db.localOrderItems).insert(
        LocalOrderItemsCompanion.insert(
          localId: 'it-c',
          workspaceId: 1,
          orderLocalId: 'ord-c',
          name: 'شاي',
          quantity: 1,
          unitPrice: 100,
          totalAmount: 100,
          updatedAt: now,
        ),
      );
      await (db.delete(db.localOrders)..where((t) => t.localId.equals('ord-c')))
          .go();
      expect(await db.select(db.localOrderItems).get(), isEmpty);
    });

    test('invoice RESTRICT blocks deleting its order', () async {
      final now = DateTime.now();
      await db.into(db.localOrders).insert(
        LocalOrdersCompanion.insert(
          localId: 'ord-r',
          workspaceId: 1,
          deviceId: 'dev-1',
          clientReference: 'ord-r',
          orderType: 'takeaway',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.into(db.localInvoices).insert(
        LocalInvoicesCompanion.insert(
          localId: 'inv-r',
          workspaceId: 1,
          deviceId: 'dev-1',
          orderLocalId: const Value('ord-r'),
          totalAmount: const Value(100),
          createdAt: now,
        ),
      );
      expect(
        () => (db.delete(db.localOrders)
              ..where((t) => t.localId.equals('ord-r')))
            .go(),
        throwsA(isA<Object>()),
      );
      expect(await db.select(db.localOrders).get(), hasLength(1));
    });

    test('deleting a category SET NULL on products', () async {
      final now = DateTime.now();
      await db.into(db.localCategories).insert(
        LocalCategoriesCompanion.insert(
          localId: 'cat-s',
          workspaceId: 1,
          name: 'أ',
          updatedAt: now,
        ),
      );
      await db.into(db.localProducts).insert(
        LocalProductsCompanion.insert(
          localId: 'prod-s',
          workspaceId: 1,
          categoryLocalId: const Value('cat-s'),
          name: 'شاي',
          updatedAt: now,
        ),
      );
      await (db.delete(db.localCategories)
            ..where((t) => t.localId.equals('cat-s')))
          .go();
      final product = await (db.select(db.localProducts)
            ..where((t) => t.localId.equals('prod-s')))
          .getSingle();
      expect(product.categoryLocalId, isNull);
    });

    test('store RESTRICT blocks deleting a store with sequences', () async {
      final now = DateTime.now();
      await db.into(db.localStores).insert(
        LocalStoresCompanion.insert(
          localId: 'store-r',
          workspaceId: 1,
          name: 'س',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.into(db.localSequences).insert(
        LocalSequencesCompanion.insert(
          storeId: 'store-r',
          kind: 'invoice',
          nextValue: 2,
          updatedAt: now,
        ),
      );
      expect(
        () => (db.delete(db.localStores)
              ..where((t) => t.localId.equals('store-r')))
            .go(),
        throwsA(isA<Object>()),
      );
    });
  });

  group('M1 money cents', () {
    test('0.1 + 0.2 is 0.3 in cents', () {
      expect(Money.toCents(0.1) + Money.toCents(0.2), 30);
      expect(Money.fromCents(30), 0.3);
    });

    test('tax and discount rounding stay deterministic', () {
      const pricing = PricingService();
      final a = pricing.quote(
        lines: const [
          PricedLine(
            productLocalId: 'p',
            name: 'A',
            quantity: 3,
            unitPrice: 1.11,
          ),
        ],
        orderDiscountPercent: 10,
        fallbackTaxRate: 15,
      );
      final b = pricing.quote(
        lines: const [
          PricedLine(
            productLocalId: 'p',
            name: 'A',
            quantity: 3,
            unitPrice: 1.11,
          ),
        ],
        orderDiscountPercent: 10,
        fallbackTaxRate: 15,
      );
      expect(a.totalCents, b.totalCents);
      expect(a.taxCents, 45);
      expect(a.totalCents, 345);
    });

    test('split payments cash change and return amounts', () async {
      final auth = LocalAuthService(db);
      final catalog = CatalogAdminService(db);
      final stock = StockEngine(db);
      final numbers = DocumentNumberService(db);
      final checkout = CheckoutService(
        db,
        stock,
        numbers,
        SyncQueueRepository(db),
      );
      final shifts = ShiftService(db);
      final created = await auth.bootstrapStore(
        storeName: 'مال',
        adminName: 'مدير',
        username: 'admin',
        pin: '1234',
      );
      final productId = await catalog.createProduct(
        workspaceId: PosMode.standaloneWorkspaceId,
        name: 'صنف',
        price: 10.5,
        permissions: adminPerms,
      );
      final shiftId = await shifts.open(
        workspaceId: PosMode.standaloneWorkspaceId,
        userId: created.user.localId,
        openingCash: 50,
        permissions: adminPerms,
      );
      final result = await checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: created.store.localId,
          permissions: adminPerms,
          clientReference: 'money-1',
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: productId,
              name: 'صنف',
              quantity: 1,
              unitPrice: 10.5,
            ),
          ],
          payments: const [
            PaymentTender(method: 'cash', amount: 5.25, tendered: 10),
            PaymentTender(method: 'card', amount: 5.25),
          ],
          shiftLocalId: shiftId,
        ),
      );
      expect(result.total, 10.5);
      expect(result.changeDue, 4.75);
      final product = await (db.select(db.localProducts)
            ..where((t) => t.localId.equals(productId)))
          .getSingle();
      expect(product.price, 1050);
      final order = await (db.select(db.localOrders)
            ..where((t) => t.localId.equals('money-1')))
          .getSingle();
      expect(order.totalAmount, 1050);
      final pays = await db.select(db.localPayments).get();
      expect(pays.map((p) => p.amount), containsAll([525, 525]));
      final cash = pays.firstWhere((p) => p.method == 'cash');
      expect(cash.tendered, 1000);
      expect(cash.changeDue, 475);
    });
  });

  group('M1 migration safety', () {
    Future<void> expectPreserved(AppDatabase migrated, {required int ws}) async {
      final product = await (migrated.select(migrated.localProducts)
            ..where((t) => t.localId.equals('prod-1')))
          .getSingle();
      expect(product.price, 1050);
      expect(product.cost, 325);
      expect(product.stock, 20);
      expect(product.workspaceId, ws);
      final invoice = await (migrated.select(migrated.localInvoices)
            ..where((t) => t.localId.equals('inv-1')))
          .getSingle();
      expect(invoice.totalAmount, 1208);
      expect(invoice.localInvoiceNumber, 'INV-000007');
      final order = await (migrated.select(migrated.localOrders)
            ..where((t) => t.localId.equals('order-1')))
          .getSingle();
      expect(order.totalAmount, 1208);
      final customer = await (migrated.select(migrated.localCustomers)
            ..where((t) => t.localId.equals('cust-1')))
          .getSingle();
      expect(customer.name, 'عميل');
      final shift = await (migrated.select(migrated.localShifts)
            ..where((t) => t.localId.equals('shift-1')))
          .getSingle();
      expect(shift.openingCash, 10000);
      final seq = await (migrated.select(migrated.localSequences)
            ..where((t) => t.storeId.equals('store-1') & t.kind.equals('invoice')))
          .getSingle();
      expect(seq.nextValue, 8);
      final draft = await (migrated.select(migrated.localDraftCarts)
            ..where((t) => t.localId.equals('draft-1')))
          .getSingle();
      expect(draft.discountAmount, 150);
      final line = await (migrated.select(migrated.localDraftCartLines)
            ..where((t) => t.localId.equals('dl-1')))
          .getSingle();
      expect(line.unitPrice, 1050);
      expect(line.quantity, 2);
    }

    test('upgrades a v6 REAL database without losing operational rows', () async {
      final dir = await Directory.systemTemp.createTemp('pos-v6');
      final file = File('${dir.path}/legacy.sqlite');
      writeLegacyPosDatabase(file: file, userVersion: 6, workspaceId: 1);
      final migrated = AppDatabase(NativeDatabase(file));
      await expectPreserved(migrated, ws: 1);
      await migrated.close();
      await dir.delete(recursive: true);
    });

    test('upgrades a v5 database and remaps standalone workspace 1', () async {
      final dir = await Directory.systemTemp.createTemp('pos-v5');
      final file = File('${dir.path}/legacy.sqlite');
      writeLegacyPosDatabase(file: file, userVersion: 5, workspaceId: 1);
      final migrated = AppDatabase(NativeDatabase(file));
      await expectPreserved(migrated, ws: PosMode.standaloneWorkspaceId);
      await migrated.close();
      await dir.delete(recursive: true);
    });
  });

  group('M2 PIN KDF', () {
    test('correct PIN logs in and wrong PIN is rejected', () async {
      final auth = LocalAuthService(db);
      await auth.bootstrapStore(
        storeName: 'PIN',
        adminName: 'مدير',
        username: 'admin',
        pin: '2468',
      );
      final user = await auth.login(
        workspaceId: PosMode.standaloneWorkspaceId,
        username: 'admin',
        pin: '2468',
      );
      expect(user.pinHash.startsWith('pbkdf2-sha256\$'), isTrue);
      expect(
        () => auth.login(
          workspaceId: PosMode.standaloneWorkspaceId,
          username: 'admin',
          pin: '0000',
        ),
        throwsA(isA<InvalidPin>()),
      );
    });

    test('legacy SHA-256 hash is verified then upgraded', () async {
      final now = DateTime.now();
      const salt = 'c2FsdA==';
      const pin = '1357';
      final legacy = sha256.convert(utf8.encode('$salt:$pin')).toString();
      await db.into(db.localUsers).insert(
        LocalUsersCompanion.insert(
          localId: 'legacy-u',
          workspaceId: PosMode.standaloneWorkspaceId,
          name: 'قديم',
          username: 'oldadmin',
          pinSalt: salt,
          pinHash: legacy,
          createdAt: now,
          updatedAt: now,
        ),
      );
      expect(PinHasher.isLegacySha256(legacy), isTrue);
      final auth = LocalAuthService(db);
      final user = await auth.login(
        workspaceId: PosMode.standaloneWorkspaceId,
        username: 'oldadmin',
        pin: pin,
      );
      expect(PinHasher.isLegacySha256(user.pinHash), isFalse);
      expect(user.pinHash.startsWith('pbkdf2-sha256\$'), isTrue);
      final again = await auth.login(
        workspaceId: PosMode.standaloneWorkspaceId,
        username: 'oldadmin',
        pin: pin,
      );
      expect(again.localId, 'legacy-u');
    });

    test('cold start and logout refuse a standalone session without PIN', () {
      expect(PosMode.admitRestoredSession('standalone:user-1'), isFalse);
      expect(PosMode.admitRestoredSession('local-offline'), isFalse);
      expect(PosMode.admitRestoredSession(null), isFalse);
      expect(PosMode.admitRestoredSession(''), isFalse);
      expect(PosMode.admitRestoredSession('laravel-jwt'), isTrue);
    });
  });

  group('M2 encrypted backup', () {
    Future<({String storeId, String invoiceId})> seedSale() async {
      final auth = LocalAuthService(db);
      final catalog = CatalogAdminService(db);
      final stock = StockEngine(db);
      final checkout = CheckoutService(
        db,
        stock,
        DocumentNumberService(db),
        SyncQueueRepository(db),
      );
      final created = await auth.bootstrapStore(
        storeName: 'نسخ',
        adminName: 'مدير',
        username: 'admin',
        pin: '1234',
      );
      final productId = await catalog.createProduct(
        workspaceId: PosMode.standaloneWorkspaceId,
        name: 'شاي',
        price: 10,
        permissions: adminPerms,
      );
      final shiftId = await ShiftService(db).open(
        workspaceId: PosMode.standaloneWorkspaceId,
        userId: created.user.localId,
        openingCash: 20,
        permissions: adminPerms,
      );
      await checkout.execute(
        CheckoutCommand(
          workspaceId: PosMode.standaloneWorkspaceId,
          deviceId: 'dev-1',
          storeId: created.store.localId,
          permissions: adminPerms,
          clientReference: 'bak-1',
          orderType: 'takeaway',
          lines: [
            PricedLine(
              productLocalId: productId,
              name: 'شاي',
              quantity: 1,
              unitPrice: 10,
            ),
          ],
          payments: const [
            PaymentTender(method: 'cash', amount: 10, tendered: 10),
          ],
          shiftLocalId: shiftId,
        ),
      );
      final invoice = (await db.select(db.localInvoices).get()).single;
      return (storeId: created.store.localId, invoiceId: invoice.localId);
    }

    test('export is encrypted and restore needs the password', () async {
      await seedSale();
      final backup = BackupService(db);
      final dir = await Directory.systemTemp.createTemp('pos-enc');
      final file = await backup.exportBackup(
        workspaceId: PosMode.standaloneWorkspaceId,
        directory: dir,
        password: 'secret12',
        permissions: adminPerms,
      );
      final envelope = jsonDecode(await file.readAsString()) as Map;
      expect(envelope['format_version'], 3);
      expect(envelope['ciphertext_b64'], isNotEmpty);
      expect(jsonEncode(envelope).contains('شاي'), isFalse);
      await backup.restoreFile(
        file,
        confirmed: true,
        password: 'secret12',
        permissions: adminPerms,
      );
      expect(await db.select(db.localInvoices).get(), hasLength(1));
      await dir.delete(recursive: true);
    });

    test('wrong password and corrupt files do not overwrite current data', () async {
      final seed = await seedSale();
      final backup = BackupService(db);
      final dir = await Directory.systemTemp.createTemp('pos-bad');
      final file = await backup.exportBackup(
        workspaceId: PosMode.standaloneWorkspaceId,
        directory: dir,
        password: 'secret12',
        permissions: adminPerms,
      );
      final envelope = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      await expectLater(
        backup.restore(
          envelope,
          confirmed: true,
          password: 'wrong-password',
          permissions: adminPerms,
        ),
        throwsA(isA<DatabaseFailure>()),
      );
      expect(
        (await db.select(db.localInvoices).get()).single.localId,
        seed.invoiceId,
      );

      envelope['ciphertext_b64'] = 'AAAA';
      await expectLater(
        backup.restore(
          envelope,
          confirmed: true,
          password: 'secret12',
          permissions: adminPerms,
        ),
        throwsA(isA<DatabaseFailure>()),
      );
      expect(await db.select(db.localInvoices).get(), hasLength(1));

      await expectLater(
        backup.restore(
          {'format_version': 99, 'workspace_id': 1, 'tables': {}},
          confirmed: true,
          permissions: adminPerms,
        ),
        throwsA(isA<DatabaseFailure>()),
      );
      expect(await db.select(db.localInvoices).get(), hasLength(1));
      await dir.delete(recursive: true);
    });

    test('format 2 major-unit backup converts to cents on restore', () async {
      await seedSale();
      final backup = BackupService(db);
      final tables = {
        'local_stores': [
          {
            'local_id': 'fmt2-store',
            'workspace_id': PosMode.standaloneWorkspaceId,
            'name': 'قديم',
            'currency': 'SAR',
            'timezone': 'Asia/Riyadh',
            'tax_rate': 0.0,
            'allow_negative_stock': 0,
            'invoice_prefix': 'INV-',
            'connected_mode': 0,
            'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          },
        ],
        'local_products': [
          {
            'local_id': 'fmt2-p',
            'workspace_id': PosMode.standaloneWorkspaceId,
            'name': 'شاي',
            'price': 10.5,
            'cost': 3.0,
            'tax_rate': 0.0,
            'is_active': 1,
            'is_deleted': 0,
            'payload_json': '{}',
            'track_stock': 0,
            'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          },
        ],
        'local_users': <Map<String, Object?>>[],
        'local_invoices': <Map<String, Object?>>[],
        'local_orders': <Map<String, Object?>>[],
        'local_order_items': <Map<String, Object?>>[],
        'local_payments': <Map<String, Object?>>[],
        'local_returns': <Map<String, Object?>>[],
        'local_return_items': <Map<String, Object?>>[],
        'local_stock_movements': <Map<String, Object?>>[],
        'local_shifts': <Map<String, Object?>>[],
        'local_cash_movements': <Map<String, Object?>>[],
        'local_sessions': <Map<String, Object?>>[],
        'local_draft_carts': <Map<String, Object?>>[],
        'local_draft_cart_lines': <Map<String, Object?>>[],
        'local_customers': <Map<String, Object?>>[],
        'local_categories': <Map<String, Object?>>[],
        'local_tables': <Map<String, Object?>>[],
        'local_settings': <Map<String, Object?>>[],
        'local_sequences': <Map<String, Object?>>[],
      };
      final payload = {
        'format_version': 2,
        'workspace_id': PosMode.standaloneWorkspaceId,
        'checksum_sha256': sha256.convert(utf8.encode(jsonEncode(tables))).toString(),
        'tables': tables,
      };
      await backup.restore(
        payload,
        confirmed: true,
        permissions: adminPerms,
      );
      final product = await (db.select(db.localProducts)
            ..where((t) => t.localId.equals('fmt2-p')))
          .getSingle();
      expect(product.price, 1050);
    });
  });

  test('standalone application modules do not import dio', () {
    const files = [
      'lib/core/pos/application/checkout_service.dart',
      'lib/core/pos/application/return_service.dart',
      'lib/core/pos/application/shift_service.dart',
      'lib/core/pos/application/reports_service.dart',
      'lib/core/pos/application/backup_service.dart',
      'lib/core/pos/application/local_auth_service.dart',
      'lib/core/pos/application/catalog_admin_service.dart',
      'lib/core/pos/application/draft_cart_store.dart',
      'lib/core/pos/application/stock_engine.dart',
      'lib/core/pos/application/document_numbers.dart',
      'lib/core/pos/domain/pricing_service.dart',
    ];
    for (final path in files) {
      final source = File(path).readAsStringSync();
      expect(
        source.contains('package:dio/dio.dart'),
        isFalse,
        reason: path,
      );
    }
  });
}
