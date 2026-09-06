import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/api/cashier_api.dart';
import 'package:hasim_cashier/core/auth/auth_controller.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/local_db_providers.dart';
import 'package:hasim_cashier/core/offline/offline_store.dart';
import 'package:hasim_cashier/core/permissions/permissions_provider.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';
import 'package:hasim_cashier/core/widgets/hasim_widgets.dart';
import 'package:hasim_cashier/features/home/shell_screen.dart';
import 'package:hasim_cashier/features/invoices/invoices_list.dart';
import 'package:hasim_cashier/features/reports/daily_reports_panel.dart';
import 'package:hive/hive.dart';

class _SilentAuthRepository extends AuthRepository {
  _SilentAuthRepository(super._api, super._storage);

  @override
  Future<AuthSession?> restore() async => null;

  @override
  Future<void> logout() async {}
}

void main() {
  late Directory hiveDir;
  late AppDatabase db;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('hasim_shell_hive');
    Hive.init(hiveDir.path);
    await OfflineStore.instance.init();
  });

  setUp(() async {
    db = AppDatabase.memory();
    const ws = PosMode.standaloneWorkspaceId;
    final now = DateTime.now();
    await db.into(db.localStores).insert(
          LocalStoresCompanion.insert(
            localId: 'store-1',
            workspaceId: ws,
            name: 'متجر الاختبار',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.localCategories).insert(
          LocalCategoriesCompanion.insert(
            localId: 'cat-drinks',
            workspaceId: ws,
            name: 'مشروبات',
            updatedAt: now,
          ),
        );
    await db.into(db.localCategories).insert(
          LocalCategoriesCompanion.insert(
            localId: 'cat-food',
            workspaceId: ws,
            name: 'أكل',
            updatedAt: now,
          ),
        );
    await db.into(db.localProducts).insert(
          LocalProductsCompanion.insert(
            localId: 'prod-tea',
            workspaceId: ws,
            name: 'شاي اختبار',
            categoryLocalId: const Value('cat-drinks'),
            price: const Value(500),
            updatedAt: now,
          ),
        );
    await db.into(db.localProducts).insert(
          LocalProductsCompanion.insert(
            localId: 'prod-burger',
            workspaceId: ws,
            name: 'برجر اختبار',
            categoryLocalId: const Value('cat-food'),
            price: const Value(1500),
            updatedAt: now,
          ),
        );
    await db.into(db.localInvoices).insert(
          LocalInvoicesCompanion.insert(
            localId: 'inv-1',
            workspaceId: ws,
            deviceId: 'dev-1',
            invoiceNumber: const Value('INV-TEST-1'),
            localInvoiceNumber: const Value('INV-TEST-1'),
            totalAmount: const Value(2300),
            createdAt: now,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpShell(WidgetTester tester, {required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          workspaceIdProvider.overrideWith(
            (ref) => PosMode.standaloneWorkspaceId,
          ),
          cashierPermissionsProvider.overrideWith(
            (ref) => Map<String, dynamic>.from(
              LocalAuthService.adminPermissions,
            ),
          ),
          authRepositoryProvider.overrideWith(
            (ref) => _SilentAuthRepository(
              ref.watch(cashierApiProvider),
              ref.watch(secureStorageProvider),
            ),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          supportedLocales: [Locale('ar'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: ShellScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('arabic top nav opens invoices and reports', (tester) async {
    await pumpShell(tester, size: const Size(1400, 900));

    expect(find.byType(HsNavPill), findsWidgets);
    expect(find.text('الكاشير'), findsOneWidget);
    expect(find.text('الفواتير'), findsOneWidget);
    expect(find.text('التقارير'), findsOneWidget);

    await tester.tap(find.text('الفواتير'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(InvoicesList), findsOneWidget);
    expect(find.text('INV-TEST-1'), findsOneWidget);

    await tester.tap(find.text('التقارير'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DailyReportsPanel), findsOneWidget);
    expect(find.text('التقارير اليومية'), findsOneWidget);

    await tester.tap(find.text('الكاشير'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('شاي اختبار'), findsWidgets);
    expect(find.text('برجر اختبار'), findsWidgets);
    expect(find.text('مشروبات'), findsWidgets);

    await tester.tap(find.text('مشروبات'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('شاي اختبار'), findsWidgets);
    expect(find.text('برجر اختبار'), findsNothing);
  });

  testWidgets('tablet cashier shows category chips and filters products',
      (tester) async {
    await pumpShell(tester, size: const Size(900, 700));

    expect(find.text('الكاشير'), findsOneWidget);
    expect(find.text('مشروبات'), findsWidgets);
    expect(find.text('شاي اختبار'), findsWidgets);
    expect(find.text('برجر اختبار'), findsWidgets);

    await tester.tap(find.text('مشروبات'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('شاي اختبار'), findsWidgets);
    expect(find.text('برجر اختبار'), findsNothing);
  });
}
