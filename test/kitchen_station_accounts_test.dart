import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hasim_cashier/core/api/cashier_api.dart';
import 'package:hasim_cashier/core/auth/auth_controller.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/local_db/local_db_providers.dart';
import 'package:hasim_cashier/core/pos/application/catalog_admin_service.dart';
import 'package:hasim_cashier/core/pos/application/kitchen_local_service.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/pos_errors.dart';
import 'package:hasim_cashier/core/pos/pos_mode.dart';
import 'package:hasim_cashier/core/repositories/local_finance_repository.dart';
import 'package:hasim_cashier/core/repositories/orders_repository.dart';
import 'package:hasim_cashier/core/repositories/sync_queue_repository.dart';
import 'package:hasim_cashier/core/permissions/permissions_provider.dart';
import 'package:hasim_cashier/core/widgets/pos_tap.dart';
import 'package:hasim_cashier/features/auth/login_screen.dart';
import 'package:hasim_cashier/features/kitchen/kitchen_board.dart';
import 'package:hasim_cashier/features/orders/orders_list.dart';
import 'package:hasim_cashier/features/reports/daily_reports_panel.dart';
import 'package:hasim_cashier/features/reports/reports_station_screen.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
  });

  const ws = PosMode.standaloneWorkspaceId;

  Future<void> seedStore() async {
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
  }

  test('admin can create cashier and chef accounts', () async {
    final auth = LocalAuthService(db);
    await auth.bootstrapStore(
      storeName: 'متجر',
      adminName: 'مدير',
      username: 'admin',
      pin: '1234',
    );
    await auth.createUser(
      workspaceId: ws,
      name: 'كاشير أحمد',
      username: 'cashier1',
      pin: '2222',
      role: 'cashier',
    );
    await auth.createUser(
      workspaceId: ws,
      name: 'شيف سامي',
      username: 'chef1',
      pin: '3333',
      role: 'chef',
    );
    final users = await auth.listUsers(ws);
    expect(users.map((u) => u.role), containsAll(['admin', 'cashier', 'chef']));
    final chef = await auth.login(
      workspaceId: ws,
      username: 'chef1',
      pin: '3333',
    );
    expect(LocalAuthService.isKitchenRole(chef.role), isTrue);
    expect(LocalAuthService.roleLabelAr(chef.role), 'شيف');
    expect(LocalAuthService.permissionsFor('chef')['kitchen.use'], isTrue);
    expect(LocalAuthService.permissionsFor('chef')['pos.use'], isNot(true));
    expect(LocalAuthService.permissionsFor('chef')['tables.manage'], isNot(true));
    expect(LocalAuthService.permissionsFor('cashier')['kitchen.use'], isNot(true));
    expect(LocalAuthService.permissionsFor('cashier')['invoices.delete'], isNot(true));
    expect(LocalAuthService.permissionsFor('cashier')['tables.create'], isNot(true));
    expect(LocalAuthService.permissionsFor('cashier')['reports.view'], isNot(true));
  });

  test('per-user ACL overlays role defaults and is enforced in services', () async {
    final auth = LocalAuthService(db);
    await auth.bootstrapStore(
      storeName: 'متجر',
      adminName: 'مدير',
      username: 'admin@store.local',
      pin: '1234',
    );
    final cashierId = await auth.createUser(
      workspaceId: ws,
      name: 'كاشير أحمد',
      username: 'cashier@store.local',
      pin: '2222',
      role: 'cashier',
    );
    await auth.writeUserAcl(
      workspaceId: ws,
      userLocalId: cashierId,
      permissions: {
        'invoices.delete': true,
        'reports.view': true,
      },
    );
    final cashier = await auth.login(
      workspaceId: ws,
      username: 'CASHIER@store.local',
      pin: '2222',
    );
    final effective = await auth.effectivePermissions(cashier);
    expect(effective['invoices.delete'], isTrue);
    expect(effective['reports.view'], isTrue);
    expect(effective['pos.use'], isTrue);
    expect(effective['tables.create'], isNot(true));

    final catalog = CatalogAdminService(db);
    expect(
      () => catalog.createTable(
        workspaceId: ws,
        name: 'طاولة ممنوعة',
        permissions: effective,
      ),
      throwsA(isA<Forbidden>()),
    );
    await catalog.createTable(
      workspaceId: ws,
      name: 'طاولة المدير',
      permissions: LocalAuthService.adminPermissions,
    );

    final finance = LocalFinanceRepository(db);
    expect(
      () => finance.deleteInvoice(
        localId: 'missing',
        permissions: LocalAuthService.permissionsFor('cashier'),
      ),
      throwsA(isA<Forbidden>()),
    );
    expect(
      () => finance.updateInvoice(
        localId: 'missing',
        notes: 'x',
        permissions: LocalAuthService.permissionsFor('cashier'),
      ),
      throwsA(isA<Forbidden>()),
    );
  });

  test('chef landing is kitchen; cashier landing is home', () {
    final chef = AuthSession(
      token: 'standalone:chef',
      user: {'name': 'سامي', 'role': 'chef'},
      workspaces: [],
      permissions: LocalAuthService.permissionsFor('chef'),
      isLocalMode: true,
    );
    final cashier = AuthSession(
      token: 'standalone:cash',
      user: {'name': 'أحمد', 'role': 'cashier'},
      workspaces: [],
      permissions: LocalAuthService.permissionsFor('cashier'),
      isLocalMode: true,
    );
    final reportsOnly = AuthSession(
      token: 'standalone:rep',
      user: {'name': 'تقارير', 'role': 'cashier'},
      workspaces: [],
      permissions: const {'reports.view': true},
      isLocalMode: true,
    );
    expect(chef.landingRoute, '/kitchen');
    expect(chef.canUsePos, isFalse);
    expect(cashier.landingRoute, '/home');
    expect(reportsOnly.landingRoute, '/reports');
  });

  test('kitchen watch includes table name without a cashier session', () async {
    await seedStore();
    final now = DateTime.now();
    await db.into(db.localTables).insert(
          LocalTablesCompanion.insert(
            localId: 'table-1',
            workspaceId: ws,
            name: 'طاولة 7',
            updatedAt: now,
          ),
        );
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-table',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-table',
            orderNumber: const Value('T-7'),
            orderType: 'table',
            tableLocalId: const Value('table-1'),
            posStatus: const Value('new'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.localOrderItems).insert(
          LocalOrderItemsCompanion.insert(
            localId: 'it-1',
            workspaceId: ws,
            orderLocalId: 'ord-table',
            name: 'برجر',
            quantity: 2,
            unitPrice: 1000,
            totalAmount: 2000,
            updatedAt: now,
          ),
        );
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-out',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-out',
            orderNumber: const Value('TW-1'),
            orderType: 'takeaway',
            posStatus: const Value('preparing'),
            createdAt: now,
            updatedAt: now,
          ),
        );

    final tickets = await KitchenLocalService(db).watchActive(ws).first;
    expect(tickets, hasLength(2));
    final tableTicket = tickets.firstWhere((e) => e['local_id'] == 'ord-table');
    expect(tableTicket['table'], isA<Map>());
    expect((tableTicket['table'] as Map)['name'], 'طاولة 7');
    expect(tableTicket['order_type'], 'table');
    final takeaway = tickets.firstWhere((e) => e['local_id'] == 'ord-out');
    expect(takeaway['order_type'], 'takeaway');
    expect(takeaway['table'], isNull);
  });

  test('listRunning shows two orders with type and table', () async {
    await seedStore();
    final now = DateTime.now();
    await db.into(db.localTables).insert(
          LocalTablesCompanion.insert(
            localId: 'table-1',
            workspaceId: ws,
            name: 'طاولة 3',
            updatedAt: now,
          ),
        );
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-a',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-a',
            orderNumber: const Value('A-1'),
            orderType: 'table',
            tableLocalId: const Value('table-1'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-b',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-b',
            orderNumber: const Value('B-2'),
            orderType: 'takeaway',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final repo = OrdersRepository(db, SyncQueueRepository(db));
    final running = await repo.listRunning(workspaceId: ws);
    expect(running, hasLength(2));
    final tableOrder = running.firstWhere((e) => e['local_id'] == 'ord-a');
    expect(tableOrder['order_type'], 'table');
    expect((tableOrder['table'] as Map)['name'], 'طاولة 3');
    expect(
      running.firstWhere((e) => e['local_id'] == 'ord-b')['order_type'],
      'takeaway',
    );
  });

  test('chef session is isolated from cashier home', () {
    const chef = AuthSession(
      token: 'standalone:chef',
      user: {'name': 'سامي', 'role': 'chef'},
      workspaces: [],
      isLocalMode: true,
    );
    const cashier = AuthSession(
      token: 'standalone:cash',
      user: {'name': 'أحمد', 'role': 'cashier'},
      workspaces: [],
      isLocalMode: true,
    );
    expect(chef.isKitchenSession, isTrue);
    expect(cashier.isKitchenSession, isFalse);
  });

  testWidgets('login shows cashier, kitchen, and reports entries when a store exists',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedStore();
    final router = GoRouter(
      initialLocation: '/login',
      routes: [
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(
          path: '/pin',
          builder: (_, __) => const Scaffold(body: Text('pin-screen')),
        ),
        GoRoute(
          path: '/kitchen',
          builder: (_, __) => const Scaffold(body: Text('kitchen-station')),
        ),
        GoRoute(
          path: '/reports',
          builder: (_, __) => const Scaffold(body: Text('reports-station')),
        ),
        GoRoute(
          path: '/standalone-setup',
          builder: (_, __) => const Scaffold(body: Text('setup-screen')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => db)],
        child: MaterialApp.router(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('setup-screen'), findsNothing);
    expect(find.text('دخول الكاشير'), findsOneWidget);
    expect(find.text('دخول المطبخ'), findsOneWidget);
    expect(find.text('دخول التقارير'), findsOneWidget);

    await tester.tap(find.text('دخول المطبخ'));
    await tester.pumpAndSettle();
    expect(find.text('kitchen-station'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('login reports entry opens the reports station', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedStore();
    final router = GoRouter(
      initialLocation: '/login',
      routes: [
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(
          path: '/reports',
          builder: (_, __) => const Scaffold(body: Text('reports-station')),
        ),
        GoRoute(
          path: '/standalone-setup',
          builder: (_, __) => const Scaffold(body: Text('setup-screen')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => db)],
        child: MaterialApp.router(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('دخول التقارير'));
    await tester.pump();
    await tester.tap(find.text('دخول التقارير'));
    await tester.pumpAndSettle();
    expect(find.text('reports-station'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('orders page places two tickets side by side', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedStore();
    final now = DateTime.now();
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-a',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-a',
            orderNumber: const Value('A-1'),
            orderType: 'takeaway',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-b',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-b',
            orderNumber: const Value('B-2'),
            orderType: 'delivery',
            createdAt: now,
            updatedAt: now,
          ),
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          workspaceIdProvider.overrideWith((ref) => ws),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          supportedLocales: [Locale('ar'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: OrdersList()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('#A-1'), findsOneWidget);
    expect(find.text('#B-2'), findsOneWidget);
    expect(find.textContaining('طلب خارجي'), findsOneWidget);
    expect(find.textContaining('توصيل'), findsOneWidget);
    expect(find.byKey(const ValueKey('orders-row-0')), findsOneWidget);
    final row = tester.widget<Row>(find.byKey(const ValueKey('orders-row-0')));
    expect(row.children.whereType<Expanded>().length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('kitchen board places two colored tickets side by side',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedStore();
    final now = DateTime.now();
    await db.into(db.localTables).insert(
          LocalTablesCompanion.insert(
            localId: 'table-1',
            workspaceId: ws,
            name: 'طاولة 9',
            updatedAt: now,
          ),
        );
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-k',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-k',
            orderNumber: const Value('K-1'),
            orderType: 'table',
            tableLocalId: const Value('table-1'),
            posStatus: const Value('new'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.into(db.localOrderItems).insert(
          LocalOrderItemsCompanion.insert(
            localId: 'it-k',
            workspaceId: ws,
            orderLocalId: 'ord-k',
            name: 'شاي',
            quantity: 1,
            unitPrice: 500,
            totalAmount: 500,
            updatedAt: now,
          ),
        );
    await db.into(db.localOrders).insert(
          LocalOrdersCompanion.insert(
            localId: 'ord-k2',
            workspaceId: ws,
            deviceId: 'dev-1',
            clientReference: 'ord-k2',
            orderNumber: const Value('K-2'),
            orderType: 'takeaway',
            posStatus: const Value('accepted'),
            createdAt: now,
            updatedAt: now,
          ),
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => db)],
        child: const MaterialApp(
          locale: Locale('ar'),
          supportedLocales: [Locale('ar'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: KitchenBoard()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('طاولة 9'), findsOneWidget);
    expect(find.textContaining('شاي'), findsOneWidget);
    expect(find.text('جديد'), findsWidgets);
    expect(find.text('مقبول'), findsWidgets);
    expect(find.byKey(const ValueKey('kitchen-row-0')), findsOneWidget);
    final row = tester.widget<Row>(find.byKey(const ValueKey('kitchen-row-0')));
    expect(row.children.whereType<Expanded>().length, 2);
    expect(find.text('الكاشير'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('reports station opens without a cashier session', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedStore();
    final now = DateTime.now();
    await db.into(db.localInvoices).insert(
          LocalInvoicesCompanion.insert(
            localId: 'inv-r',
            workspaceId: ws,
            deviceId: 'dev-1',
            invoiceNumber: const Value('INV-R-1'),
            localInvoiceNumber: const Value('INV-R-1'),
            totalAmount: const Value(1500),
            createdAt: now,
          ),
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          workspaceIdProvider.overrideWith((ref) => ws),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          supportedLocales: [Locale('ar'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: ReportsStationScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('غير مصرح بعرض التقارير'), findsNothing);
    expect(find.text('التقارير اليومية'), findsOneWidget);
    expect(find.text('المطبخ'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('daily reports panel renders local data', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedStore();
    final now = DateTime.now();
    await db.into(db.localInvoices).insert(
          LocalInvoicesCompanion.insert(
            localId: 'inv-r',
            workspaceId: ws,
            deviceId: 'dev-1',
            invoiceNumber: const Value('INV-R-1'),
            localInvoiceNumber: const Value('INV-R-1'),
            totalAmount: const Value(1500),
            createdAt: now,
          ),
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          workspaceIdProvider.overrideWith((ref) => ws),
          cashierPermissionsProvider.overrideWith(
            (ref) => Map<String, dynamic>.from(
              LocalAuthService.adminPermissions,
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
          home: Scaffold(body: DailyReportsPanel()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('التقارير اليومية'), findsOneWidget);
    await tester.dragUntilVisible(
      find.textContaining('INV-R-1'),
      find.byType(Scrollable).first,
      const Offset(0, -240),
    );
    expect(find.textContaining('INV-R-1'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets(
    'reports station hover during load does not trip mouse_tracker',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final errors = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details.exception);
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);

      bool hasHitTestStorm() => errors.any(
            (e) =>
                '$e'.contains('no size') ||
                '$e'.contains('_debugDuringDeviceUpdate') ||
                '$e'.contains('PointerAddedEvent') ||
                '$e'.contains('Null check operator'),
          );

      await seedStore();
      final now = DateTime.now();
      await db.into(db.localInvoices).insert(
            LocalInvoicesCompanion.insert(
              localId: 'inv-hover',
              workspaceId: ws,
              deviceId: 'dev-1',
              invoiceNumber: const Value('INV-HOVER-1'),
              localInvoiceNumber: const Value('INV-HOVER-1'),
              totalAmount: const Value(900),
              createdAt: now,
            ),
          );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('ar'),
            supportedLocales: [Locale('ar'), Locale('en')],
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: ReportsStationScreen(),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(24, 24));
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(const Offset(640, 28));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(const Offset(720, 28));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('غير مصرح بعرض التقارير'), findsNothing);
      expect(find.text('التقارير اليومية'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(PosTap), findsWidgets);

      await gesture.moveTo(tester.getCenter(find.text('المطبخ')));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('reports-date-chip'))),
      );
      await tester.pump();
      container.read(invoicesRevisionProvider.notifier).state++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveTo(tester.getCenter(find.text('إجمالي المبيعات')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('خروج')));
      await tester.pump();

      expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    },
  );
}
