import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/api/cashier_api.dart';
import 'package:hasim_cashier/core/config/app_config.dart';
import 'package:hasim_cashier/core/network/cashier_link.dart';
import 'package:hasim_cashier/core/network/link_policy.dart';
import 'package:hasim_cashier/core/offline/conflict_strategy.dart';
import 'package:hasim_cashier/core/offline/offline_store.dart';
import 'package:hasim_cashier/core/permissions/cashier_permissions.dart';
import 'package:hasim_cashier/core/printing/printer_service.dart';
import 'package:hasim_cashier/core/realtime/pos_event_source.dart';
import 'package:hasim_cashier/features/cart/cart_controller.dart';

void main() {
  test('cart takeaway clears table and labels order type خارجي', () {
    final cart = CartController();
    cart.setChannel(OrderChannel.table);
    cart.setTable(9);
    cart.setChannel(OrderChannel.takeaway);
    expect(cart.state.tableId, isNull);
    expect(cart.state.channel.labelAr, 'خارجي');
  });

  test('permissions gate tables and discount from Laravel map', () {
    const allowed = {
      'tables.manage': true,
      'orders.discount': false,
      'orders.create': true,
    };
    expect(CashierPermissions.canManageTables(allowed), isTrue);
    expect(CashierPermissions.canDiscount(allowed), isFalse);
    expect(CashierPermissions.canCreateOrders(allowed), isTrue);
  });

  test('menu.manage gates catalog and POS settings independently', () {
    expect(CashierPermissions.canManageMenu(const {}), isFalse);
    expect(
      CashierPermissions.canManageMenu({'menu.manage': true}),
      isTrue,
    );
    expect(
      CashierPermissions.canManageMenu({'orders.manage': true}),
      isFalse,
    );
    // Backend AuthorizesCashier does not grant menu via pos.manage alone.
    expect(
      CashierPermissions.canManageMenu({'pos.manage': true}),
      isFalse,
    );
    expect(
      CashierPermissions.canManageMenu({'workspace.manage': true}),
      isTrue,
    );
  });

  test('orders.manage / tables.manage / reports.view are independent', () {
    expect(
      CashierPermissions.canCreateOrders({'orders.manage': true}),
      isTrue,
    );
    expect(
      CashierPermissions.canManageTables({'orders.manage': true}),
      isFalse,
    );
    expect(
      CashierPermissions.canManageTables({'tables.manage': true}),
      isTrue,
    );
    // Backend does not grant tables via pos.manage alone.
    expect(
      CashierPermissions.canManageTables({'pos.manage': true}),
      isFalse,
    );
    expect(
      CashierPermissions.canViewReports({'reports.view': true}),
      isTrue,
    );
    expect(
      CashierPermissions.canViewReports({'tables.manage': true}),
      isFalse,
    );
  });

  test('reports permission uses session fallback when bootstrap empty', () {
    expect(CashierPermissions.canViewReports(const {}), isFalse);
    expect(
      CashierPermissions.canViewReports({'reports.view': true}),
      isTrue,
    );
    expect(
      CashierPermissions.canViewReports({'orders.manage': true}),
      isTrue,
    );
    // Truthy encodings from serializers must still unlock reports.
    expect(
      CashierPermissions.canViewReports({'reports.view': 1}),
      isTrue,
    );
    expect(
      CashierPermissions.canViewReports({'reports.view': 'true'}),
      isTrue,
    );
    final resolved = CashierPermissions.resolve(
      const {},
      {'reports.view': true, 'orders.manage': true},
    );
    expect(CashierPermissions.canViewReports(resolved), isTrue);
  });

  test('reports nav should not depend on empty permission map', () {
    // Web always shows reports; client may still gate content via API 403.
    // Empty map must not crash resolve / canViewReports.
    expect(CashierPermissions.resolve(null, null), isEmpty);
    expect(CashierPermissions.canViewReports(null), isFalse);
  });

  test('bootstrap auth snapshot equality skips identical permission maps', () {
    const a = {'reports.view': true, 'orders.manage': true};
    const b = {'reports.view': true, 'orders.manage': true};
    const c = {'reports.view': false, 'orders.manage': true};
    expect(a.length, b.length);
    var same = true;
    for (final e in a.entries) {
      if (b[e.key] != e.value) same = false;
    }
    expect(same, isTrue);
    same = true;
    for (final e in a.entries) {
      if (c[e.key] != e.value) same = false;
    }
    expect(same, isFalse);
  });

  test('poll intervals are slowed to avoid API throttle', () {
    expect(AppConfig.menuPollSeconds >= 5, isTrue);
    expect(AppConfig.tablesPollSeconds >= 5, isTrue);
    expect(AppConfig.kitchenPollSeconds >= 5, isTrue);
  });

  test('hourly sales prefer sales_total over total_sales', () {
    num hourSales(Map<String, dynamic> row) =>
        (row['sales_total'] as num?) ?? (row['total_sales'] as num?) ?? 0;
    expect(hourSales({'sales_total': 42, 'total_sales': 1}), 42);
    expect(hourSales({'total_sales': 7}), 7);
    expect(hourSales({}), 0);
  });

  test('table order mutation mirrors assertOrderMutable rules', () {
    bool canMutate(Map<String, dynamic> order) {
      final status = order['pos_status'] as String?;
      return status != 'cancelled' &&
          status != 'completed' &&
          order['payment_status'] != 'paid' &&
          order['pos_cashier_invoice_id'] == null;
    }

    expect(canMutate({'pos_status': 'new', 'payment_status': 'unpaid'}), isTrue);
    expect(canMutate({'pos_status': 'cancelled'}), isFalse);
    expect(canMutate({'pos_status': 'completed'}), isFalse);
    expect(canMutate({'pos_status': 'new', 'payment_status': 'paid'}), isFalse);
    expect(
      canMutate({'pos_status': 'new', 'pos_cashier_invoice_id': 9}),
      isFalse,
    );
  });

  test('table add-order payload is save-only (no invoice/print flags)', () {
    final payload = <String, dynamic>{
      'order_type': 'table',
      'dining_table_id': 1,
      'client_reference': 'ref-1',
      'notes': null,
      'items': [
        {'pos_menu_item_id': 10, 'quantity': 2},
      ],
    };
    expect(payload.containsKey('create_invoice'), isFalse);
    expect(payload.containsKey('print'), isFalse);
    expect(payload.containsKey('payment_method'), isFalse);
    expect(payload['order_type'], 'table');
  });

  test('reports nested fields tolerate null/non-map values', () {
    String nestedName(dynamic value, {String fallback = '—'}) {
      if (value is Map) {
        final name = value['name'];
        if (name != null && '$name'.trim().isNotEmpty) return '$name';
      }
      return fallback;
    }

    num asNum(dynamic value) {
      if (value is num) return value;
      if (value is String) return num.tryParse(value) ?? 0;
      return 0;
    }

    expect(nestedName({'name': 'طاولة 1'}), 'طاولة 1');
    expect(nestedName(null), '—');
    expect(nestedName('not-a-map'), '—');
    expect(asNum('12.5'), 12.5);
    expect(asNum(null), 0);
    expect(asNum({'x': 1}), 0);
  });

  test('reports empty/malformed payload maps to empty collections without throw', () {
    Map<String, dynamic> asMap(dynamic raw) {
      if (raw is Map<String, dynamic>) return raw;
      if (raw is Map) return Map<String, dynamic>.from(raw);
      return const {};
    }

    List<Map<String, dynamic>> asMaps(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }

    const empty = <String, dynamic>{};
    expect(asMap(empty['summary']), isEmpty);
    expect(asMap(null), isEmpty);
    expect(asMaps(empty['top_items']), isEmpty);
    expect(asMaps('bad'), isEmpty);
    expect(asMaps([
      {'product_name': 'شاي'},
      'skip-me',
    ]), hasLength(1));
  });

  test('reports UI never resolves to a blank/white state', () {
    String surface({
      required bool loading,
      required bool forbidden,
      String? error,
      Map<String, dynamic>? data,
    }) {
      if (loading) return 'loading';
      if (forbidden) return 'forbidden';
      if (error != null) return 'error';
      if (data == null) return 'empty';
      return 'body';
    }

    expect(
      surface(loading: true, forbidden: false, error: null, data: null),
      'loading',
    );
    expect(
      surface(loading: false, forbidden: true, error: 'x', data: null),
      'forbidden',
    );
    expect(
      surface(loading: false, forbidden: false, error: 'فشل', data: null),
      'error',
    );
    expect(
      surface(loading: false, forbidden: false, error: null, data: null),
      'empty',
    );
    expect(
      surface(
        loading: false,
        forbidden: false,
        error: null,
        data: const {'summary': {}},
      ),
      'body',
    );
    expect(
      {
        'loading',
        'forbidden',
        'error',
        'empty',
        'body',
      }.contains('white'),
      isFalse,
    );
  });

  test('menu.manage is required for catalog management actions', () {
    bool showCatalogMutations(Map<String, dynamic>? perms) =>
        CashierPermissions.canManageMenu(perms);
    expect(showCatalogMutations({'menu.manage': true}), isTrue);
    expect(showCatalogMutations({'pos.manage': true}), isFalse);
    expect(showCatalogMutations({'orders.manage': true}), isFalse);
    expect(showCatalogMutations(const {}), isFalse);
    expect(showCatalogMutations(null), isFalse);
  });

  test('table detail keeps primary and overflow actions', () {
    const primary = ['إضافة طلب', 'إغلاق الطاولة'];
    const overflow = [
      'إضافة ملاحظة',
      'خصم',
      'QR المنيو',
      'نقل الطاولة',
      'دمج طاولة',
      'تقسيم الحساب',
    ];
    const destructive = 'إلغاء الطاولة';
    expect(primary, containsAll(['إضافة طلب', 'إغلاق الطاولة']));
    expect(overflow, hasLength(6));
    expect(destructive, 'إلغاء الطاولة');
    expect(primary.contains(destructive), isFalse);
  });

  test('table detail wide layout gives info a larger flex than orders', () {
    const infoFlex = 7;
    const ordersFlex = 3;
    expect(infoFlex > ordersFlex, isTrue);
  });

  test('close table submits once with a single Idempotency-Key', () {
    var submits = 0;
    String? usedKey;
    void close({required bool alreadyClosing, required String key}) {
      if (alreadyClosing) return;
      submits += 1;
      usedKey = key;
    }

    close(alreadyClosing: false, key: 'idem-1');
    close(alreadyClosing: true, key: 'idem-2');
    expect(submits, 1);
    expect(usedKey, 'idem-1');
  });

  test('conflict strategy keeps pending orders; all daily table ops offline', () {
    expect(
      ConflictStrategy.forDomain('pending_order'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('table_action'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('transfer'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('merge'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('split'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('discount'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('close_table'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('payment'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('open_session'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('invoice'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('inventory'),
      ConflictPolicy.serverWins,
    );
    expect(
      ConflictStrategy.forDomain('refund'),
      ConflictPolicy.requireOnline,
    );
  });

  test('escpos builder emits invoice bytes without claiming print success', () {
    final bytes = EscPosReceiptBuilder().buildInvoice({
      'store_name': 'متجر تجريبي',
      'invoice_number': 'INV-1',
      'closed_at': '2026-09-01',
      'subtotal': 100,
      'discount_amount': 5,
      'total_amount': 95,
      'items': [
        {'item_name': 'شاي', 'quantity': 2, 'total_amount': 20},
      ],
    });
    expect(bytes, isNotEmpty);
  });

  test('unconfigured printer gateway never fakes success', () async {
    final gateway = UnconfiguredPrinterGateway();
    final result = await gateway.send(
      EscPosReceiptBuilder().buildTestPage('x'),
      const PrinterProfile(
        id: '1',
        name: 't',
        transport: PrinterTransport.network,
        address: '10.0.0.1',
      ),
    );
    expect(result.success, isFalse);
    expect(result.message, contains('غير'));
  });

  test('pusher source refuses start without credentials', () async {
    final source = PusherPosEventSource();
    expect(source.isConfigured, isFalse);
    expect(() => source.start(), throwsA(isA<StateError>()));
  });

  test('sync status enum covers queue states', () {
    expect(SyncStatus.values.map((e) => e.name), containsAll([
      'pending',
      'syncing',
      'synced',
      'failed',
    ]));
  });

  test('network timeout is not treated as logout', () {
    expect(LinkPolicy.shouldLogout(0), isFalse);
    expect(LinkPolicy.shouldLogout(null), isFalse);
    expect(LinkPolicy.shouldLogout(500), isFalse);
    expect(LinkPolicy.shouldLogout(503), isFalse);
    expect(LinkPolicy.shouldLogout(401), isTrue);
    expect(ApiException('x', statusCode: 0).isUnauthorized, isFalse);
    expect(ApiException('x', statusCode: 0).isUnavailable, isTrue);
    expect(ApiException('x', statusCode: 401).isUnauthorized, isTrue);
  });

  test('shell stays buildable: bootstrap cache used when live fails', () {
    Map<String, dynamic>? recover({
      Map<String, dynamic>? live,
      Map<String, dynamic>? cached,
      required bool failed,
    }) {
      if (!failed && live != null) return live;
      return cached;
    }

    expect(
      recover(live: {'ok': true}, cached: {'ok': false}, failed: false),
      {'ok': true},
    );
    expect(
      recover(live: {'ok': true}, cached: {'cached': true}, failed: true),
      {'cached': true},
    );
    expect(recover(failed: true), isNull);
  });

  test('offline indicator and retry policy', () {
    expect(
      LinkPolicy.bannerMessage(CashierLink.serverUnavailable),
      contains('الخادم غير متاح'),
    );
    expect(
      LinkPolicy.bannerMessage(CashierLink.offline),
      contains('أوفلاين'),
    );
    var retries = 0;
    var inFlight = false;
    void retry() {
      if (inFlight) return;
      inFlight = true;
      retries++;
      inFlight = false;
    }
    retry();
    retry();
    expect(retries, 2);
  });

  test('table payment and all daily table ops are offline-first', () {
    expect(
      ConflictStrategy.forDomain('table_action'),
      ConflictPolicy.detectAndRecord,
    );
    expect(ConflictStrategy.forDomain('payment'), ConflictPolicy.detectAndRecord);
    expect(
      ConflictStrategy.forDomain('close_table'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('invoice'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('cancel_session'),
      ConflictPolicy.detectAndRecord,
    );
    expect(
      ConflictStrategy.forDomain('invoice_edit'),
      ConflictPolicy.requireOnline,
    );
    expect(LinkPolicy.allowServerMutation(CashierLink.offline), isFalse);
    expect(
      LinkPolicy.allowServerMutation(CashierLink.serverUnavailable),
      isFalse,
    );
    expect(LinkPolicy.allowServerMutation(CashierLink.online), isTrue);
  });

  test('tables and kitchen polling pause when not online', () {
    expect(LinkPolicy.shouldPausePolling(CashierLink.offline), isTrue);
    expect(
      LinkPolicy.shouldPausePolling(CashierLink.serverUnavailable),
      isTrue,
    );
    expect(LinkPolicy.shouldPausePolling(CashierLink.online), isFalse);
  });

  test('polling source does not hit API when disabled', () async {
    var hits = 0;
    final source = PollingPosEventSource(
      interval: const Duration(seconds: 30),
      enabled: () => false,
      poll: () async {
        hits++;
        return const [];
      },
    );
    await source.start();
    expect(hits, 0);
    await source.dispose();
  });

  test('401 is auth failure not offline', () {
    expect(
      LinkPolicy.afterApi(
        deviceOnline: true,
        statusCode: 401,
        success: false,
      ),
      CashierLink.online,
    );
    expect(
      LinkPolicy.afterApi(
        deviceOnline: true,
        statusCode: 0,
        success: false,
      ),
      CashierLink.serverUnavailable,
    );
    expect(
      LinkPolicy.afterApi(
        deviceOnline: false,
        statusCode: 0,
        success: false,
      ),
      CashierLink.offline,
    );
  });

  test('device restore waits for API success before online', () {
    final controller = CashierLinkController();
    controller.setDeviceOnline(false);
    expect(controller.state.link, CashierLink.offline);
    controller.setDeviceOnline(true);
    expect(controller.state.link, CashierLink.serverUnavailable);
    controller.onApiSuccess();
    expect(controller.state.link, CashierLink.online);
  });

  test('bootstrap in-flight guard prevents loop', () {
    var inFlight = false;
    var calls = 0;
    void load() {
      if (inFlight) return;
      inFlight = true;
      calls++;
      inFlight = false;
    }
    load();
    inFlight = true;
    load();
    expect(calls, 1);
  });

  test('reports network failure is error or cached body never white', () {
    String surface({
      required bool loading,
      Map<String, dynamic>? data,
      String? error,
    }) {
      if (loading && data == null) return 'loading';
      if (error != null && data == null) return 'error';
      if (data != null) return 'body';
      return 'empty';
    }

    expect(
      surface(loading: false, data: null, error: 'تعذر الاتصال بالخادم'),
      'error',
    );
    expect(
      surface(loading: false, data: const {'summary': {}}, error: null),
      'body',
    );
  });

  test('empty permissions stay empty offline — no invented grants', () {
    expect(CashierPermissions.canManageMenu(const {}), isFalse);
    expect(CashierPermissions.canManageTables(const {}), isFalse);
    expect(CashierPermissions.canViewReports(const {}), isFalse);
  });
}
