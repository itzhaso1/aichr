import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/pos/application/backup_service.dart';
import 'package:hasim_cashier/core/pos/application/catalog_admin_service.dart';
import 'package:hasim_cashier/core/pos/application/checkout_service.dart';
import 'package:hasim_cashier/core/pos/application/document_numbers.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/application/reports_service.dart';
import 'package:hasim_cashier/core/pos/application/shift_service.dart';
import 'package:hasim_cashier/core/pos/application/stock_engine.dart';
import 'package:hasim_cashier/core/pos/domain/pricing_service.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';

const adminPerms = LocalAuthService.adminPermissions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'dataset of 10k invoices and 100k items stays usable',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
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
        storeName: 'حجم',
        adminName: 'مدير',
        username: 'admin',
        pin: '1234',
      );
      final ws = PosMode.standaloneWorkspaceId;
      final now = DateTime.now();
      // Drift DateTime columns are UNIX seconds.
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      final saleProduct = await catalog.createProduct(
        workspaceId: ws,
        name: 'بيع',
        price: 10,
        barcode: 'SALE-1',
        stock: 100000,
        trackStock: true,
        permissions: adminPerms,
      );
      final shiftId = await ShiftService(db).open(
        workspaceId: ws,
        userId: created.user.localId,
        openingCash: 100,
        permissions: adminPerms,
      );

      await db.transaction(() async {
        for (var i = 0; i < 2000; i++) {
          await db.customStatement(
            'INSERT INTO local_products (local_id, workspace_id, name, barcode, '
            'price, is_active, is_deleted, payload_json, stock, cost, tax_rate, '
            'track_stock, updated_at) VALUES (?, ?, ?, ?, 199, 1, 0, "{}", 5, 50, '
            '0, 1, ?)',
            ['p-$i', ws, 'صنف $i', 'BC-${i.toString().padLeft(6, '0')}', nowSec],
          );
        }
        const invoices = 10000;
        const itemsPer = 10;
        for (var i = 0; i < invoices; i++) {
          final orderId = 'o-$i';
          final invoiceId = 'i-$i';
          await db.customStatement(
            'INSERT INTO local_orders (local_id, workspace_id, device_id, '
            'client_reference, order_type, subtotal, tax_amount, '
            'discount_amount, total_amount, pos_status, payment_status, '
            'fulfillment_status, sync_status, retry_count, created_at, '
            'updated_at) VALUES (?, ?, "dev-1", ?, "takeaway", 1000, 0, 0, '
            '1000, "completed", "paid", "unfulfilled", "local", 0, ?, ?)',
            [orderId, ws, orderId, nowSec, nowSec],
          );
          await db.customStatement(
            'INSERT INTO local_invoices (local_id, workspace_id, device_id, '
            'invoice_number, local_invoice_number, order_local_id, status, '
            'subtotal, discount_amount, tax_amount, total_amount, sync_status, '
            'payload_json, created_at) VALUES (?, ?, "dev-1", ?, ?, ?, '
            '"closed", 1000, 0, 0, 1000, "local", "{}", ?)',
            [
              invoiceId,
              ws,
              'STRESS-${i.toString().padLeft(6, '0')}',
              'STRESS-${i.toString().padLeft(6, '0')}',
              orderId,
              nowSec,
            ],
          );
          final values = StringBuffer();
          final args = <Object?>[];
          for (var j = 0; j < itemsPer; j++) {
            if (j > 0) values.write(',');
            values.write('(?,?,?,?,?,?,?,0,0,100,0,?)');
            args.addAll([
              'oi-$i-$j',
              ws,
              orderId,
              'بند $j',
              1,
              100,
              100,
              nowSec,
            ]);
          }
          await db.customStatement(
            'INSERT INTO local_order_items (local_id, workspace_id, '
            'order_local_id, name, quantity, unit_price, total_amount, '
            'discount_amount, tax_amount, cost_snapshot, is_removed, '
            'updated_at) VALUES $values',
            args,
          );
        }
      });

      expect(await db.customSelect('SELECT COUNT(*) AS c FROM local_invoices').get(),
          isNotEmpty);
      final invoiceCount = (await db.customSelect(
        'SELECT COUNT(*) AS c FROM local_invoices',
      ).get())
          .single
          .data['c'];
      final itemCount = (await db.customSelect(
        'SELECT COUNT(*) AS c FROM local_order_items',
      ).get())
          .single
          .data['c'];
      expect(invoiceCount, 10000);
      expect(itemCount, 100000);

      Future<int> timed(
        String name,
        Future<void> Function() body, {
        int maxMs = 15000,
      }) async {
        final sw = Stopwatch()..start();
        await body();
        sw.stop();
        // ignore: avoid_print
        print('STRESS $name ${sw.elapsedMilliseconds}ms');
        expect(
          sw.elapsedMilliseconds,
          lessThan(maxMs),
          reason: '$name exceeded ${maxMs}ms (${sw.elapsedMilliseconds}ms)',
        );
        return sw.elapsedMilliseconds;
      }

      await timed('open POS catalog', () async {
        final rows = await db.customSelect(
          'SELECT local_id, name, price, barcode, stock FROM local_products '
          'WHERE workspace_id = ? AND is_deleted = 0 AND is_active = 1 '
          'ORDER BY name LIMIT 80',
          variables: [Variable.withInt(ws)],
        ).get();
        expect(rows.length, 80);
      });

      await timed('product search', () async {
        final rows = await db.customSelect(
          "SELECT local_id, name FROM local_products "
          "WHERE workspace_id = ? AND is_deleted = 0 AND name LIKE ? LIMIT 20",
          variables: [
            Variable.withInt(ws),
            Variable.withString('%صنف 12%'),
          ],
        ).get();
        expect(rows, isNotEmpty);
      });

      await timed('barcode lookup', () async {
        final hit = await catalog.findByBarcode(
          workspaceId: ws,
          barcode: 'BC-000100',
        );
        expect(hit?['name'], 'صنف 100');
      });

      await timed('checkout', () async {
        final result = await checkout.execute(
          CheckoutCommand(
            workspaceId: ws,
            deviceId: 'dev-1',
            storeId: created.store.localId,
            permissions: adminPerms,
            clientReference: 'stress-sale',
            orderType: 'takeaway',
            lines: [
              PricedLine(
                productLocalId: saleProduct,
                name: 'بيع',
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
        expect(result.total, 10);
      });

      await timed('invoice list', () async {
        final rows = await db.customSelect(
          'SELECT local_id, local_invoice_number, total_amount FROM '
          'local_invoices WHERE workspace_id = ? ORDER BY created_at DESC '
          'LIMIT 50',
          variables: [Variable.withInt(ws)],
        ).get();
        expect(rows.length, 50);
      });

      await timed('reports', () async {
        final report = await LocalReportsService(db).daily(
          workspaceId: ws,
          date: now,
        );
        expect(report['summary']['invoices_count'], greaterThanOrEqualTo(10000));
      });

      await timed('stock query', () async {
        final snap = await LocalReportsService(db).stockSnapshot(ws);
        expect((snap['products'] as List).length, greaterThan(2000));
      });

      final dir = await Directory.systemTemp.createTemp('pos-stress-bak');
      addTearDown(() => dir.delete(recursive: true));
      late File backupFile;
      await timed(
        'backup',
        () async {
          backupFile = await BackupService(db).exportBackup(
            workspaceId: ws,
            directory: dir,
            password: 'secret12',
            permissions: adminPerms,
          );
          expect(await backupFile.exists(), isTrue);
        },
        maxMs: 60000,
      );

      await timed(
        'restore',
        () async {
          await BackupService(db).restoreFile(
            backupFile,
            confirmed: true,
            password: 'secret12',
            permissions: adminPerms,
          );
          final after = (await db.customSelect(
            'SELECT COUNT(*) AS c FROM local_invoices',
          ).get())
              .single
              .data['c'];
          expect(after, greaterThanOrEqualTo(10000));
        },
        maxMs: 60000,
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
