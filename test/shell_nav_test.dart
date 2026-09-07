import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/api/cashier_api.dart';
import 'package:hasim_cashier/core/auth/auth_controller.dart';
import 'package:hasim_cashier/core/device/device_identity.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/local_db_providers.dart';
import 'package:hasim_cashier/core/offline/offline_store.dart';
import 'package:hasim_cashier/core/permissions/permissions_provider.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/application/pos_providers.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';
import 'package:hasim_cashier/core/widgets/hasim_widgets.dart';
import 'package:hasim_cashier/core/widgets/occupied_duration_label.dart';
import 'package:hasim_cashier/features/admin/users_admin_panel.dart';
import 'package:hasim_cashier/features/home/shell_screen.dart';
import 'package:hasim_cashier/features/invoices/invoices_list.dart';
import 'package:hasim_cashier/features/kitchen/kitchen_board.dart';
import 'package:hasim_cashier/features/reports/daily_reports_panel.dart';
import 'package:hasim_cashier/features/tables/tables_board.dart';
import 'package:hive/hive.dart';

class _ImmediateDeviceIdentity extends DeviceIdentity {
  _ImmediateDeviceIdentity() : super(const FlutterSecureStorage());

  @override
  Future<String> getOrCreateDeviceId() async => 'test-device';
}

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
    await db
        .into(db.localStores)
        .insert(
          LocalStoresCompanion.insert(
            localId: 'store-1',
            workspaceId: ws,
            name: 'متجر الاختبار',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.localCategories)
        .insert(
          LocalCategoriesCompanion.insert(
            localId: 'cat-drinks',
            workspaceId: ws,
            name: 'مشروبات',
            updatedAt: now,
          ),
        );
    await db
        .into(db.localCategories)
        .insert(
          LocalCategoriesCompanion.insert(
            localId: 'cat-food',
            workspaceId: ws,
            name: 'أكل',
            updatedAt: now,
          ),
        );
    await db
        .into(db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            localId: 'prod-tea',
            workspaceId: ws,
            name: 'شاي اختبار',
            categoryLocalId: const Value('cat-drinks'),
            price: const Value(500),
            updatedAt: now,
          ),
        );
    await db
        .into(db.localProducts)
        .insert(
          LocalProductsCompanion.insert(
            localId: 'prod-burger',
            workspaceId: ws,
            name: 'برجر اختبار',
            categoryLocalId: const Value('cat-food'),
            price: const Value(1500),
            updatedAt: now,
          ),
        );
    await db
        .into(db.localInvoices)
        .insert(
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
    await LocalAuthService(db).createUser(
      workspaceId: PosMode.standaloneWorkspaceId,
      name: 'مدير الاختبار',
      username: 'admin@test.com',
      pin: '1234',
      role: 'admin',
    );
    await db
        .into(db.localShifts)
        .insert(
          LocalShiftsCompanion.insert(
            localId: 'shift-1',
            workspaceId: ws,
            openedAt: now,
            status: const Value('open'),
          ),
        );
    await db
        .into(db.localTables)
        .insert(
          LocalTablesCompanion.insert(
            localId: 'table-1',
            workspaceId: ws,
            serverId: const Value(1),
            name: 'طاولة 1',
            status: const Value('available'),
            payloadJson: const Value(
              '{"id":1,"name":"طاولة 1","status":"available"}',
            ),
            updatedAt: now,
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
          currentStoreIdProvider.overrideWith((ref) => 'store-1'),
          currentShiftIdProvider.overrideWith((ref) => 'shift-1'),
          deviceIdentityProvider.overrideWith(
            (ref) => _ImmediateDeviceIdentity(),
          ),
          cashierPermissionsProvider.overrideWith(
            (ref) =>
                Map<String, dynamic>.from(LocalAuthService.adminPermissions),
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

  Future<void> tapNav(WidgetTester tester, String label) async {
    final finder = find.text(label);
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openStationFromSettings(
    WidgetTester tester,
    String actionLabel,
  ) async {
    await tapNav(tester, 'الإعدادات');
    await tester.ensureVisible(find.text(actionLabel));
    await tester.tap(find.text(actionLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  bool hasHitTestStorm(List<Object> errors) => errors.any(
    (e) =>
        '$e'.contains('no size') ||
        '$e'.contains('was not laid out') ||
        '$e'.contains('_debugDuringDeviceUpdate') ||
        '$e'.contains('_debugDoingThisLayout') ||
        '$e'.contains('PointerAddedEvent') ||
        '$e'.contains('Null check operator'),
  );

  testWidgets(
    'top nav has no reports/kitchen shortcuts and opens invoices/users',
    (tester) async {
      await pumpShell(tester, size: const Size(1400, 900));

      expect(find.byType(HsNavPill), findsWidgets);
      expect(find.text('الكاشير'), findsOneWidget);
      expect(find.text('الفواتير'), findsOneWidget);
      expect(find.text('المستخدمون'), findsOneWidget);
      expect(find.text('الإعدادات'), findsOneWidget);
      expect(find.text('التقارير'), findsNothing);
      expect(find.text('المطبخ'), findsNothing);
      expect(find.text('العملاء'), findsNothing);

      await tapNav(tester, 'الفواتير');
      expect(find.byType(InvoicesList), findsOneWidget);
      expect(find.text('INV-TEST-1'), findsOneWidget);

      await tapNav(tester, 'المستخدمون');
      expect(find.byType(UsersAdminPanel), findsOneWidget);
      expect(find.text('المستخدمون والصلاحيات'), findsOneWidget);
      final editorScrollable = find
          .descendant(
            of: find.byType(UsersAdminPanel),
            matching: find.byType(Scrollable),
          )
          .last;
      await tester.scrollUntilVisible(
        find.text('الدخول إلى صفحة التقارير'),
        240,
        scrollable: editorScrollable,
      );
      expect(find.text('الدخول إلى صفحة التقارير'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('الدخول إلى صفحة المطبخ'),
        120,
        scrollable: editorScrollable,
      );
      expect(find.text('الدخول إلى صفحة المطبخ'), findsOneWidget);

      await openStationFromSettings(tester, 'فتح التقارير');
      expect(find.byType(DailyReportsPanel), findsOneWidget);
      expect(find.text('التقارير اليومية'), findsOneWidget);

      await openStationFromSettings(tester, 'فتح المطبخ');
      expect(find.byType(KitchenBoard), findsOneWidget);

      await tapNav(tester, 'الكاشير');
      expect(find.text('شاي اختبار'), findsWidgets);
      expect(find.text('برجر اختبار'), findsWidgets);
      expect(find.text('مشروبات'), findsWidgets);
      expect(find.text('طلب جديد'), findsOneWidget);
      expect(find.text('طاولة'), findsWidgets);
      expect(find.text('توصيل'), findsOneWidget);
      expect(find.text('طلب خارجي'), findsOneWidget);
      expect(find.text('التقارير'), findsNothing);
      expect(find.text('المطبخ'), findsNothing);

      await tester.tap(find.text('مشروبات'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('شاي اختبار'), findsWidgets);
      expect(find.text('برجر اختبار'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  testWidgets('tablet cashier shows category chips and filters products', (
    tester,
  ) async {
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

  testWidgets(
    'invoices users reports and kitchen layout at common Windows sizes',
    (tester) async {
      for (final size in const [
        Size(1280, 720),
        Size(1024, 768),
        Size(800, 600),
      ]) {
        await pumpShell(tester, size: size);
        await tapNav(tester, 'الفواتير');
        expect(tester.takeException(), isNull);
        expect(find.byType(InvoicesList), findsOneWidget);
        expect(find.text('INV-TEST-1'), findsOneWidget);
        expect(find.byType(HsSoftGrid), findsWidgets);

        await tapNav(tester, 'المستخدمون');
        expect(tester.takeException(), isNull);
        expect(find.byType(UsersAdminPanel), findsOneWidget);
        expect(find.text('المستخدمون والصلاحيات'), findsOneWidget);

        await openStationFromSettings(tester, 'فتح التقارير');
        expect(tester.takeException(), isNull);
        expect(find.byType(DailyReportsPanel), findsOneWidget);
        expect(find.text('التقارير اليومية'), findsOneWidget);
        expect(find.textContaining('فواتير'), findsWidgets);

        await openStationFromSettings(tester, 'فتح المطبخ');
        expect(tester.takeException(), isNull);
        expect(find.byType(KitchenBoard), findsOneWidget);

        await tapNav(tester, 'الكاشير');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));
      }
    },
  );

  testWidgets('checkout writes invoice then occupies the selected table', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(1400, 900));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ProductCard), findsWidgets);
    await tester.tap(find.byType(ProductCard).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('السلة فارغة.'), findsNothing);

    await tester.tap(find.text('طاولة').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('اختر الطاولة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('طاولة 1'), findsWidgets);
    await tester.tap(find.text('طاولة 1').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('إنشاء الطلب'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);

    final invoices = await db.select(db.localInvoices).get();
    final snackTexts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(
      invoices.length,
      greaterThanOrEqualTo(2),
      reason: 'checkout did not persist an invoice. snackbars=$snackTexts',
    );
    expect(
      find.text('تم حفظ الفاتورة بنجاح'),
      findsOneWidget,
      reason: 'snackbars=$snackTexts invoiceCount=${invoices.length}',
    );
    final table = await (db.select(
      db.localTables,
    )..where((t) => t.localId.equals('table-1'))).getSingle();
    expect(table.status, 'occupied');
    expect(table.payloadJson.contains('opened_at'), isTrue);

    await tester.tap(find.widgetWithText(HsOutlineButton, 'إغلاق'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tapNav(tester, 'الفواتير');
    expect(find.byType(InvoicesList), findsOneWidget);
    expect(find.text('INV-TEST-1'), findsOneWidget);
    expect(find.textContaining('INV-'), findsWidgets);

    await openStationFromSettings(tester, 'فتح التقارير');
    expect(find.byType(DailyReportsPanel), findsOneWidget);
    expect(find.text('التقارير اليومية'), findsOneWidget);

    await tapNav(tester, 'الطاولات');
    expect(find.byType(TablesBoard), findsOneWidget);
    expect(find.text('مشغولة'), findsWidgets);
    expect(find.byType(OccupiedDurationLabel), findsWidgets);
    expect(find.textContaining(RegExp(r'\d{2}:\d{2}:\d{2}')), findsWidgets);

    await tester.tap(find.text('طاولة 1').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('إغلاق الطاولة'), findsOneWidget);
    await tester.tap(find.text('إغلاق الطاولة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('التالي'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('التالي'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('إتمام الإغلاق'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final closed = await (db.select(
      db.localTables,
    )..where((t) => t.localId.equals('table-1'))).getSingle();
    expect(closed.status, 'available');
    expect(
      closed.payloadJson.contains('"opened_at":null') ||
          !closed.payloadJson.contains('"opened_at":"'),
      isTrue,
    );
    expect((await db.select(db.localInvoices).get()).length, invoices.length);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets(
    'switching invoices users reports kitchen under mouse has no layout storm',
    (tester) async {
      final errors = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details.exception);
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);

      await pumpShell(tester, size: const Size(1280, 720));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(40, 40));
      addTearDown(gesture.removePointer);
      await tester.pump();

      Future<void> hoverAndOpen(String label) async {
        await tester.ensureVisible(find.text(label));
        await gesture.moveTo(tester.getCenter(find.text(label)));
        await tester.pump();
        await tester.tap(find.text(label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await hoverAndOpen('الفواتير');
      expect(find.byType(InvoicesList), findsOneWidget);
      await hoverAndOpen('المستخدمون');
      expect(find.byType(UsersAdminPanel), findsOneWidget);
      await hoverAndOpen('الإعدادات');
      await tester.ensureVisible(find.text('فتح التقارير'));
      await gesture.moveTo(tester.getCenter(find.text('فتح التقارير')));
      await tester.pump();
      await tester.tap(find.text('فتح التقارير'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DailyReportsPanel), findsOneWidget);
      await hoverAndOpen('الإعدادات');
      await tester.ensureVisible(find.text('فتح المطبخ'));
      await tester.tap(find.text('فتح المطبخ'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(KitchenBoard), findsOneWidget);
      await hoverAndOpen('الكاشير');

      expect(tester.takeException(), isNull);
      expect(hasHitTestStorm(errors), isFalse, reason: errors.join('\n'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  testWidgets('invoice grids filter compact delete and table picker dialog', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(1400, 900));

    await tapNav(tester, 'الفواتير');
    expect(find.byType(InvoicesList), findsOneWidget);
    expect(find.byType(HsSoftGrid), findsWidgets);
    expect(find.text('INV-TEST-1'), findsOneWidget);

    await tester.tap(find.text('INV-TEST-1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('طباعة'), findsOneWidget);
    expect(find.text('إعادة'), findsOneWidget);
    expect(find.text('حذف'), findsOneWidget);

    await tester.tap(find.text('حذف'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('حذف الفاتورة'), findsOneWidget);
    expect(find.text('إلغاء'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(Dialog), findsNothing);

    await tapNav(tester, 'إدارة الأصناف');
    expect(find.text('إدارة الأصناف'), findsWidgets);
    expect(find.byType(HsSoftGrid), findsWidgets);
    expect(find.text('مشروبات'), findsWidgets);
    expect(find.text('شاي اختبار'), findsWidgets);

    await tapNav(tester, 'الإعدادات');
    expect(find.byType(HsSoftGrid), findsWidgets);
    expect(find.text('فتح التقارير'), findsOneWidget);
    expect(find.text('فتح المطبخ'), findsOneWidget);
    expect(find.text('افتتاح الكاش'), findsWidgets);
    expect(find.text('إغلاق الكاش'), findsOneWidget);

    await tester.ensureVisible(find.text('فتح التقارير'));
    await tester.tap(find.text('فتح التقارير'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DailyReportsPanel), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('فواتير اليوم'),
      find.byType(Scrollable).last,
      const Offset(0, -280),
    );
    expect(find.text('فواتير اليوم'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('كل الفواتير'),
      find.byType(Scrollable).last,
      const Offset(0, -160),
    );
    expect(find.text('كل الفواتير'), findsOneWidget);
    await tester.tap(find.text('كل الفواتير'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.textContaining('INV-TEST-1'), findsWidgets);
    await tester.tap(find.textContaining('INV-TEST-1').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(HsSoftGrid), findsWidgets);
    expect(find.byType(HsSelectField), findsOneWidget);

    await tapNav(tester, 'الكاشير');
    await tester.tap(find.text('طاولة').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('اختر الطاولة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('طاولة 1'), findsWidgets);
    await tester.tap(find.text('طاولة 1').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('طاولة 1'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
