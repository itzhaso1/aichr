import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/api/cashier_api.dart';
import '../../core/navigation/pos_shell_nav.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/offline/offline_store.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/pos/application/checkout_service.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/printing/printer_service.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/theme/hasim_spacing.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../../core/widgets/pos_tap.dart';
import '../admin/admin_placeholders.dart';
import '../cart/cart_controller.dart';
import '../customers/customers_panel.dart';
import '../invoices/invoices_list.dart';
import '../kitchen/kitchen_board.dart';
import '../orders/menu_orders_feed.dart';
import '../orders/orders_list.dart';
import '../reports/daily_reports_panel.dart';
import '../settings/settings_panel.dart';
import '../tables/tables_board.dart';
import '../../core/pos/domain/pricing_service.dart';

enum _PosSection {
  cashier,
  tables,
  orders,
  menu,
  kitchen,
  invoices,
  customers,
  items,
  reports,
  settings,
}

class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  _PosSection _section = _PosSection.cashier;
  String? _selectedCategoryId;
  final _search = TextEditingController();
  var _bootstrapInFlight = false;
  var _checkoutInFlight = false;
  String? _checkoutClientRef;

  @override
  void initState() {
    super.initState();
    _loadBootstrap();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadBootstrap() async {
    if (_bootstrapInFlight) return;
    _bootstrapInFlight = true;
    // Seed permissions from auth session immediately so reports/nav aren't
    // hidden while bootstrap is in-flight (root cause of missing reports).
    final session = ref.read(authControllerProvider).valueOrNull;
    final sessionPerms = session?.permissions;
    if (sessionPerms != null &&
        sessionPerms.isNotEmpty &&
        ref.read(cashierPermissionsProvider).isEmpty) {
      ref.read(cashierPermissionsProvider.notifier).state =
          Map<String, dynamic>.from(sessionPerms);
    }
    // Offline-only: local SQLite path only — never hit API / sync.
    final store = await ref.read(localAuthServiceProvider).anyStore();
    if (store != null) {
      ref.read(currentStoreIdProvider.notifier).state = store.localId;
      ref.read(posConnectedModeProvider.notifier).state = false;
      ref.read(cartControllerProvider.notifier).setTaxRate(store.taxRate);
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId != null) {
      final shift = await ref
          .read(shiftServiceProvider)
          .currentOpen(workspaceId);
      if (shift != null) {
        ref.read(currentShiftIdProvider.notifier).state = shift.localId;
      }
    }
    _applyBootstrapPayload({
      'pos_enabled': true,
      'permissions': sessionPerms ?? const {},
      'workspace': session?.workspace,
      'user': session?.user,
      'settings': {'tax_rate': store?.taxRate ?? 0},
    }, fromCache: true);
    if (workspaceId != null) {
      ref.invalidate(localPosReadyProvider(workspaceId));
      ref.invalidate(catalogItemsProvider);
      ref.invalidate(categoriesProvider);
    }
    if (mounted) setState(() {});
    _bootstrapInFlight = false;
  }

  void _applyBootstrapPayload(
    Map<String, dynamic> data, {
    required bool fromCache,
  }) {
    final settings = data['settings'];
    if (settings is Map && settings['tax_rate'] != null) {
      ref
          .read(cartControllerProvider.notifier)
          .setTaxRate(asDoubleOr(settings['tax_rate']));
    }
    if (data['permissions'] is Map) {
      final perms = Map<String, dynamic>.from(data['permissions'] as Map);
      ref.read(cashierPermissionsProvider.notifier).state = perms;
      ref
          .read(authControllerProvider.notifier)
          .applyBootstrapSnapshot(
            permissions: perms,
            workspace: data['workspace'] is Map
                ? Map<String, dynamic>.from(data['workspace'] as Map)
                : null,
            entitlements: data['entitlements'] is Map
                ? Map<String, dynamic>.from(data['entitlements'] as Map)
                : null,
            posEnabled: data['pos_enabled'] == true ? true : null,
          );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PosShellTab?>(posShellNavProvider, (prev, next) {
      if (next == null) return;
      setState(() {
        _section = switch (next) {
          PosShellTab.cashier => _PosSection.cashier,
          PosShellTab.tables => _PosSection.tables,
          PosShellTab.orders => _PosSection.orders,
          PosShellTab.menu => _PosSection.menu,
          PosShellTab.kitchen => _PosSection.kitchen,
          PosShellTab.invoices => _PosSection.invoices,
          PosShellTab.customers => _PosSection.customers,
          PosShellTab.items => _PosSection.items,
          PosShellTab.reports => _PosSection.reports,
          PosShellTab.sync => _PosSection.settings, // sync removed — offline only
          PosShellTab.settings => _PosSection.settings,
        };
      });
      Future.microtask(
        () => ref.read(posShellNavProvider.notifier).state = null,
      );
    });

    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= 1100;
    final isTablet = width >= 800 && width < 1100;
    // Do NOT watch the full cart / auth session object here — every change
    // would rebuild the product grid under a hovering mouse and trip
    // mouse_tracker / no-size asserts.
    final workspaceName = ref.watch(
      authControllerProvider.select(
        (auth) =>
            (auth.valueOrNull?.workspace?['name'] as String?) ?? 'المتجر المحلي',
      ),
    );

    return Scaffold(
      body: Column(
        children: [
          _TopHeader(
            workspaceName: workspaceName,
            onCart: isDesktop ? null : () => _openCartSheet(context),
            onLogout: () async {
              await ref.read(authControllerProvider.notifier).logout();
              if (context.mounted) context.go('/login');
            },
          ),
          _TopNav(
            section: _section,
            onSelect: (s) => setState(() => _section = s),
          ),
          Expanded(
            child: switch (_section) {
              _PosSection.cashier => _CashierHome(
                isDesktop: isDesktop,
                isTablet: isTablet,
                search: _search,
                selectedCategoryId: _selectedCategoryId,
                onCategory: (id) => setState(() => _selectedCategoryId = id),
                onCheckout: _checkout,
                onOpenMobileCart: () => _openCartSheet(context),
              ),
              _PosSection.tables => const TablesBoard(),
              _PosSection.orders => const OrdersList(),
              _PosSection.menu => const MenuOrdersFeed(),
              _PosSection.kitchen => const KitchenBoard(),
              _PosSection.invoices => const InvoicesList(),
              _PosSection.customers => const CustomersPanel(),
              _PosSection.items => const ItemsAdminPanel(),
              _PosSection.reports => const DailyReportsPanel(),
              _PosSection.settings => const SettingsPanel(),
            },
          ),
        ],
      ),
      floatingActionButton: (!isDesktop && _section == _PosSection.cashier)
          ? _MobileCartFab(onOpen: () => _openCartSheet(context))
          : null,
    );
  }

  Future<void> _openCartSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.82,
          child: Material(
            color: HasimColors.page,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(HasimRadius.lg),
            ),
            child: _CartPanel(onCheckout: _checkout),
          ),
        ),
      ),
    );
  }

  Future<void> _checkout() async {
    if (_checkoutInFlight) return;
    final cart = ref.read(cartControllerProvider);
    if (cart.lines.isEmpty) return;
    final perms = ref.read(cashierPermissionsProvider);
    if (!CashierPermissions.canCreateOrders(perms)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية إنشاء طلبات.')),
      );
      return;
    }
    if (cart.channel == OrderChannel.table &&
        cart.tableId == null &&
        (cart.tableLocalId == null || cart.tableLocalId!.isEmpty)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('اختر طاولة لطلب الطاولة.')));
      return;
    }

    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا توجد مساحة عمل محددة.')));
      return;
    }

    final session = ref.read(authControllerProvider).valueOrNull;

    var shiftId = ref.read(currentShiftIdProvider);
    shiftId ??= (await ref.read(shiftServiceProvider).currentOpen(workspaceId))
        ?.localId;
    if (shiftId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('افتح وردية أولاً من الإعدادات.')),
      );
      return;
    }
    ref.read(currentShiftIdProvider.notifier).state = shiftId;

    // Cashier checkout: create the order immediately — no payment dialog.
    // Default tender is cash for the full cart total.
    final payments = <PaymentTender>[
      PaymentTender(method: 'cash', amount: Money.round(cart.total)),
    ];

    _checkoutInFlight = true;
    _checkoutClientRef ??= const Uuid().v4();
    final clientRef = _checkoutClientRef!;

    try {
      final deviceId = await ref
          .read(deviceIdentityProvider)
          .getOrCreateDeviceId();
      var storeId = ref.read(currentStoreIdProvider);
      if (storeId == null) {
        final store = await ref.read(localAuthServiceProvider).anyStore();
        storeId = store?.localId ?? 'local-store';
        if (store != null) {
          ref.read(currentStoreIdProvider.notifier).state = store.localId;
        }
      }
      String? sessionId = cart.tableLocalId == null
          ? null
          : await ref
                .read(tableSessionServiceProvider)
                .open(
                  workspaceId: workspaceId,
                  tableLocalId: cart.tableLocalId!,
                  openedByUserId: ref.read(currentLocalUserIdProvider),
                );
      final store = await ref.read(localAuthServiceProvider).anyStore();
      final resolvedPerms = CashierPermissions.resolve(
        ref.read(cashierPermissionsProvider),
        session?.permissions,
      );
      final result = await ref
          .read(checkoutServiceProvider)
          .execute(
            CheckoutCommand(
              workspaceId: workspaceId,
              deviceId: deviceId,
              storeId: storeId,
              clientReference: clientRef,
              orderType: cart.channel.name,
              lines: [for (final line in cart.lines) line.toPriced()],
              payments: payments,
              tableLocalId: cart.tableLocalId,
              tableServerId: cart.tableId,
              sessionLocalId: sessionId,
              customerLocalId: cart.customerLocalId,
              notes: cart.notes,
              orderDiscountAmount: cart.discountAmount,
              orderDiscountPercent: cart.discountPercent,
              taxRate: cart.taxRate,
              createdByUserId: ref.read(currentLocalUserIdProvider),
              shiftLocalId: shiftId,
              allowNegativeStock: store?.allowNegativeStock ?? false,
              connected: false,
              invoicePrefix: store?.invoicePrefix ?? 'INV-',
              permissions: resolvedPerms,
              clearDraftChannel: cart.channel.name,
              clearDraftTableLocalId: cart.tableLocalId,
            ),
          );

      ref.read(cartControllerProvider.notifier).clear();
      _checkoutClientRef = null;
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _SuccessOrderDialog(
          orderNumber: result.invoiceNumber,
          onPrint: () async {
            Navigator.pop(context);
            try {
              final invoice = await ref
                  .read(localFinanceRepositoryProvider)
                  .getInvoice(
                    workspaceId: workspaceId,
                    localId: result.invoiceLocalId,
                  );
              if (invoice == null) {
                throw const PrinterFailure('الفاتورة غير موجودة للطباعة.');
              }
              final printer = await ref.read(
                printerServiceFutureProvider.future,
              );
              final printResult = await printer.printInvoice(invoice);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    printResult.success
                        ? 'تمت الطباعة. الفاتورة ${result.invoiceNumber}'
                        : 'اكتمل البيع. ${printResult.message}',
                  ),
                ),
              );
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('اكتمل البيع. تعذر الطباعة: $e')),
              );
            }
          },
          onContinue: () => Navigator.pop(context),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final message = e is PosException ? e.messageAr : e.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      _checkoutInFlight = false;
    }
  }
}

class _TopHeader extends ConsumerWidget {
  const _TopHeader({
    required this.workspaceName,
    required this.onLogout,
    this.onCart,
  });

  final String workspaceName;
  final VoidCallback onLogout;
  final VoidCallback? onCart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cartCount = ref.watch(
      cartControllerProvider.select(
        (c) => c.lines.fold<int>(0, (s, l) => s + l.quantity),
      ),
    );
    return Material(
      color: HasimColors.surface.withValues(alpha: 0.95),
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: HasimColors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      workspaceName,
                      style: const TextStyle(
                        fontSize: 11,
                        color: HasimColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Text(
                      'واجهة الكاشير',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const Text(
                'أوفلاين',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: HasimColors.muted,
                ),
              ),
              const SizedBox(width: 8),
              if (onCart != null)
                PosTap(
                  onTap: onCart,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.shopping_bag_outlined),
                        if (cartCount > 0) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: HasimColors.cta,
                              borderRadius: BorderRadius.circular(
                                HasimRadius.pill,
                              ),
                            ),
                            child: Text(
                              '$cartCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              PosTap(
                onTap: onLogout,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    'خروج',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: HasimColors.ink,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileCartFab extends ConsumerWidget {
  const _MobileCartFab({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(
      cartControllerProvider.select((c) => c.lines.length),
    );
    return PosTap(
      onTap: onOpen,
      child: Material(
        elevation: 4,
        color: HasimColors.cta,
        borderRadius: BorderRadius.circular(HasimRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.shopping_bag_outlined,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'السلة ($lines)',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopNav extends ConsumerWidget {
  const _TopNav({required this.section, required this.onSelect});

  final _PosSection section;
  final ValueChanged<_PosSection> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Match Web POS top-nav: reports always visible (auth happens on API).
    final items = <(_PosSection, String)>[
      (_PosSection.cashier, 'الكاشير'),
      (_PosSection.tables, 'الطاولات'),
      (_PosSection.menu, 'طلبات المنيو'),
      (_PosSection.orders, 'الطلبات'),
      (_PosSection.kitchen, 'المطبخ'),
      (_PosSection.invoices, 'الفواتير'),
      (_PosSection.reports, 'التقارير'),
      if (CashierPermissions.canManageMenu(
        CashierPermissions.resolve(
          ref.watch(cashierPermissionsProvider),
          ref.watch(authControllerProvider).valueOrNull?.permissions,
        ),
      ))
        (_PosSection.items, 'إدارة الأصناف'),
      (_PosSection.customers, 'العملاء'),
      (_PosSection.settings, 'الإعدادات'),
    ];
    final menuBadge = ref.watch(menuNewOrdersCountProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: const BoxDecoration(
        color: HasimColors.surface,
        border: Border(bottom: BorderSide(color: HasimColors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final item in items) ...[
              Stack(
                clipBehavior: Clip.none,
                children: [
                  HsNavPill(
                    label: item.$2,
                    selected: section == item.$1,
                    onTap: () => onSelect(item.$1),
                  ),
                  if (item.$1 == _PosSection.menu && menuBadge > 0)
                    Positioned(
                      top: -4,
                      left: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: HasimColors.warning,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          '$menuBadge',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _CashierHome extends ConsumerWidget {
  const _CashierHome({
    required this.isDesktop,
    required this.isTablet,
    required this.search,
    required this.selectedCategoryId,
    required this.onCategory,
    required this.onCheckout,
    required this.onOpenMobileCart,
  });

  final bool isDesktop;
  final bool isTablet;
  final TextEditingController search;
  final String? selectedCategoryId;
  final ValueChanged<String?> onCategory;
  final Future<void> Function() onCheckout;
  final VoidCallback onOpenMobileCart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    final items = ref.watch(catalogItemsProvider);

    if (isDesktop || isTablet) {
      return Padding(
        padding: const EdgeInsets.all(HasimSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isDesktop)
              SizedBox(
                width: 180,
                child: HsCard(
                  padding: const EdgeInsets.all(8),
                  child: categories.when(
                    data: (list) => ListView(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                          child: Text(
                            'التصنيفات',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: HasimColors.muted,
                            ),
                          ),
                        ),
                        HsCategoryTile(
                          label: 'الكل',
                          count: (items.valueOrNull ?? []).length,
                          selected: selectedCategoryId == null,
                          onTap: () => onCategory(null),
                        ),
                        for (final cat in list)
                          HsCategoryTile(
                            label: (cat['name'] as String?) ?? '',
                            count: (items.valueOrNull ?? [])
                                .where(
                                  (i) =>
                                      '${i['category_local_id'] ?? i['pos_item_category_id']}' ==
                                      '${cat['local_id'] ?? cat['id']}',
                                )
                                .length,
                            selected:
                                selectedCategoryId ==
                                '${cat['local_id'] ?? cat['id']}',
                            onTap: () =>
                                onCategory('${cat['local_id'] ?? cat['id']}'),
                          ),
                      ],
                    ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Text('$e'),
                  ),
                ),
              ),
            if (isDesktop) const SizedBox(width: 10),
            Expanded(
              flex: 7,
              child: HsCard(
                padding: const EdgeInsets.all(10),
                child: RepaintBoundary(
                  child: _ProductsPanel(
                    search: search,
                    selectedCategoryId: selectedCategoryId,
                    onCategory: onCategory,
                    showMobileCategories: !isDesktop,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: isDesktop ? 280 : 260,
              child: _CartPanel(onCheckout: onCheckout),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(HasimSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          categories.when(
            data: (list) => SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _chip(
                    'الكل',
                    selectedCategoryId == null,
                    () => onCategory(null),
                  ),
                  for (final cat in list)
                    _chip(
                      (cat['name'] as String?) ?? '',
                      selectedCategoryId == '${cat['local_id'] ?? cat['id']}',
                      () => onCategory('${cat['local_id'] ?? cat['id']}'),
                    ),
                ],
              ),
            ),
            loading: () => const LinearProgressIndicator(),
            error: (e, _) {
              final offline = OfflineStore.instance.readCategories(
                workspaceId: ref.read(workspaceIdProvider),
              );
              if (offline.isEmpty) {
                return HsEmpty(
                  title: 'تعذر تحميل التصنيفات',
                  subtitle: '$e',
                  actionLabel: 'إعادة',
                  onAction: () => ref.invalidate(categoriesProvider),
                );
              }
              return SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _chip(
                      'الكل',
                      selectedCategoryId == null,
                      () => onCategory(null),
                    ),
                    for (final cat in offline)
                      _chip(
                        (cat['name'] as String?) ?? '',
                        selectedCategoryId == '${cat['local_id'] ?? cat['id']}',
                        () => onCategory('${cat['local_id'] ?? cat['id']}'),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: HsCard(
              child: RepaintBoundary(
                child: _ProductsPanel(
                  search: search,
                  selectedCategoryId: selectedCategoryId,
                  onCategory: onCategory,
                  showMobileCategories: false,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: PosTap(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          constraints: const BoxConstraints(minHeight: 44, minWidth: 64),
          decoration: BoxDecoration(
            color: selected ? HasimColors.brand : HasimColors.surface,
            borderRadius: BorderRadius.circular(HasimRadius.md),
            border: Border.all(
              color: selected ? HasimColors.brand : HasimColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : HasimColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProductsPanel extends ConsumerStatefulWidget {
  const _ProductsPanel({
    required this.search,
    required this.selectedCategoryId,
    required this.onCategory,
    required this.showMobileCategories,
  });

  final TextEditingController search;
  final String? selectedCategoryId;
  final ValueChanged<String?> onCategory;
  final bool showMobileCategories;

  @override
  ConsumerState<_ProductsPanel> createState() => _ProductsPanelState();
}

class _ProductsPanelState extends ConsumerState<_ProductsPanel> {
  @override
  void initState() {
    super.initState();
    widget.search.addListener(_onSearch);
  }

  @override
  void didUpdateWidget(covariant _ProductsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.search != widget.search) {
      oldWidget.search.removeListener(_onSearch);
      widget.search.addListener(_onSearch);
    }
  }

  @override
  void dispose() {
    widget.search.removeListener(_onSearch);
    super.dispose();
  }

  void _onSearch() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(catalogItemsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final crossAxis = width >= 1500
        ? 5
        : width >= 1200
        ? 4
        : width >= 900
        ? 3
        : 2;
    final search = widget.search;
    final selectedCategoryId = widget.selectedCategoryId;
    final onCategory = widget.onCategory;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'أصناف الكاشير',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ),
            SizedBox(
              width: width >= 500 ? 260 : 160,
              child: TextField(
                controller: search,
                onSubmitted: (raw) async {
                  final workspaceId = ref.read(workspaceIdProvider);
                  if (workspaceId == null || raw.trim().isEmpty) return;
                  final hit = await ref
                      .read(barcodeInputProvider)
                      .lookup(workspaceId: workspaceId, raw: raw.trim());
                  if (hit == null) {
                    if (mounted) setState(() {});
                    return;
                  }
                  ref.read(cartControllerProvider.notifier).addItem(
                        productLocalId: '${hit['local_id']}',
                        menuItemId: asInt(hit['id']),
                        name: '${hit['name']}',
                        unitPrice: asDoubleOr(hit['price']),
                        taxRate: asDoubleOr(hit['tax_rate']),
                        cost: asDoubleOr(hit['cost']),
                        sku: hit['sku'] as String?,
                        barcode: hit['barcode'] as String?,
                      );
                  search.clear();
                  if (mounted) setState(() {});
                },
                decoration: const InputDecoration(
                  hintText: 'ابحث بالاسم أو الباركود أو SKU...',
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: items.when(
            data: (list) {
              final q = search.text.trim().toLowerCase();
              final filtered = list.where((item) {
                if (selectedCategoryId != null &&
                    '${item['category_local_id'] ?? item['pos_item_category_id']}' !=
                        selectedCategoryId) {
                  return false;
                }
                if (q.isEmpty) return true;
                final hay = '${item['name']}|${item['sku']}|${item['barcode']}'
                    .toLowerCase();
                return hay.contains(q);
              }).toList();

              if (filtered.isEmpty) {
                final offline = OfflineStore.instance.readCatalog(
                  workspaceId: ref.read(workspaceIdProvider),
                );
                if (list.isEmpty && offline.isNotEmpty) {
                  return _grid(ref, offline, crossAxis);
                }
                return HsEmpty(
                  title: 'لا توجد منتجات في هذا التصنيف.',
                  actionLabel: 'عرض الكل',
                  onAction: () {
                    onCategory(null);
                    search.clear();
                    setState(() {});
                  },
                );
              }
              OfflineStore.instance.cacheCatalog(
                list,
                workspaceId: ref.read(workspaceIdProvider),
              );
              return _grid(ref, filtered, crossAxis);
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) {
              final offline = OfflineStore.instance.readCatalog(
                workspaceId: ref.read(workspaceIdProvider),
              );
              if (offline.isNotEmpty) return _grid(ref, offline, crossAxis);
              return HsEmpty(title: 'تعذر تحميل المنتجات', subtitle: '$e');
            },
          ),
        ),
      ],
    );
  }

  Widget _grid(WidgetRef ref, List<Map<String, dynamic>> items, int crossAxis) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? (constraints.maxWidth - (10 * (crossAxis - 1))) / crossAxis
            : 140.0;
        final ratio = cellW >= 180 ? 0.72 : 0.78;
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxis,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: ratio,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final id = asIntOr(item['id']);
            final name = '${item['name'] ?? ''}';
            final price = asDoubleOr(item['price']);
            final available = item['is_active'] != false &&
                item['availability'] != 'unavailable';
            return ProductCard(
              key: ValueKey(
                (item['local_id'] as String?) ??
                    (item['id']?.toString() ?? '$index-$name'),
              ),
              name: name,
              priceLabel: price.toStringAsFixed(2),
              currency: '${item['currency'] ?? 'SAR'}',
              imageUrl: item['image_url'] as String?,
              sku: item['sku'] as String?,
              available: available,
              onAdd: () {
                final localId = (item['local_id'] as String?) ??
                    (item['id']?.toString() ?? name);
                ref.read(cartControllerProvider.notifier).addItem(
                      productLocalId: localId,
                      menuItemId: id == 0 ? null : id,
                      name: name,
                      unitPrice: price,
                      taxRate: asDoubleOr(item['tax_rate']),
                      cost: asDoubleOr(item['cost']),
                      sku: item['sku'] as String?,
                      barcode: item['barcode'] as String?,
                    );
              },
            );
          },
        );
      },
    );
  }
}

class _CartPanel extends ConsumerStatefulWidget {
  const _CartPanel({required this.onCheckout});

  final Future<void> Function() onCheckout;

  @override
  ConsumerState<_CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends ConsumerState<_CartPanel> {
  List<Map<String, dynamic>> _tables = const [];
  final _notesController = TextEditingController();
  var _metaLoaded = false;

  @override
  void initState() {
    super.initState();
    // Never kick off setState from build — schedule after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureMeta();
    });
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _syncNotesFromCart(String? notes) {
    final next = notes ?? '';
    if (_notesController.text == next) return;
    // Writing TextEditingController during build marks the element dirty mid-frame
    // and can cascade into semantics.parentDataDirty assertion storms.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_notesController.text != next) {
        _notesController.text = next;
      }
    });
  }

  Future<void> _ensureMeta() async {
    if (_metaLoaded) return;
    _metaLoaded = true;
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) return;
    try {
      // Local SQLite only — never hit the network from the cart panel.
      final local = await ref
          .read(tablesRepositoryProvider)
          .listTables(workspaceId);
      if (!mounted) return;
      if (local.isNotEmpty) {
        setState(() => _tables = local);
      }
    } catch (_) {
      // Offline — takeaway still works without tables list.
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartControllerProvider);
    final notifier = ref.read(cartControllerProvider.notifier);
    if (cart.notes != null &&
        cart.notes!.isNotEmpty &&
        _notesController.text != cart.notes) {
      _syncNotesFromCart(cart.notes);
    }

    return HsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const Text(
                  'طلب جديد',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                const Text(
                  'نوع الطلب',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (final channel in OrderChannel.values)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(end: 4),
                          child: _OrderTypeChip(
                            label: channel.labelAr,
                            selected: cart.channel == channel,
                            onTap: () => notifier.setChannel(channel),
                          ),
                        ),
                      ),
                  ],
                ),
                if (cart.channel == OrderChannel.table) ...[
                  const SizedBox(height: 8),
                  _TablePickerField(
                    tables: _tables,
                    selectedId: cart.tableId,
                    onSelected: (id, {String? localId}) =>
                        notifier.setTable(id, tableLocalId: localId),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: _notesController,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظات',
                    isDense: true,
                  ),
                  maxLines: 2,
                  onChanged: notifier.setNotes,
                ),
                const SizedBox(height: 8),
                TextField(
                  enabled: CashierPermissions.canDiscount(
                    ref.watch(cashierPermissionsProvider),
                  ),
                  decoration: InputDecoration(
                    labelText:
                        CashierPermissions.canDiscount(
                          ref.watch(cashierPermissionsProvider),
                        )
                        ? 'الخصم (مبلغ)'
                        : 'الخصم (غير مسموح)',
                    isDense: true,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged:
                      CashierPermissions.canDiscount(
                        ref.watch(cashierPermissionsProvider),
                      )
                      ? (v) => notifier.setDiscount(double.tryParse(v) ?? 0)
                      : null,
                ),
                const SizedBox(height: 10),
                const Text(
                  'ملخص الطلب',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                if (cart.lines.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'السلة فارغة.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: HasimColors.muted),
                    ),
                  )
                else
                  for (var index = 0; index < cart.lines.length; index++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(HasimRadius.sm),
                          border: Border.all(color: HasimColors.border),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    cart.lines[index].name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  cart.lines[index].unitPrice.toStringAsFixed(
                                    2,
                                  ),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: HasimColors.muted,
                                  ),
                                ),
                                PosTap(
                                  onTap: () => notifier.removeItem(
                                    cart.lines[index].productLocalId,
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    child: Text(
                                      'حذف',
                                      style: TextStyle(
                                        color: HasimColors.danger,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                _qtyBtn(
                                  '-',
                                  () => notifier.setQuantity(
                                    cart.lines[index].productLocalId,
                                    cart.lines[index].quantity - 1,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Text('${cart.lines[index].quantity}'),
                                ),
                                _qtyBtn(
                                  '+',
                                  () => notifier.setQuantity(
                                    cart.lines[index].productLocalId,
                                    cart.lines[index].quantity + 1,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  cart.lines[index].lineTotal.toStringAsFixed(
                                    2,
                                  ),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                const Divider(height: 16),
                _money('المجموع الفرعي', cart.subtotal),
                _money('الخصم', cart.discountAmount),
                _money('الضريبة', cart.taxAmount),
                _money('الإجمالي', cart.total, bold: true),
              ],
            ),
          ),
          const SizedBox(height: 10),
          HsPrimaryButton(
            label: 'إنشاء الطلب',
            onPressed: cart.lines.isEmpty ? null : () => widget.onCheckout(),
          ),
          const SizedBox(height: 6),
          HsOutlineButton(
            label: 'طلب خارجي',
            onPressed: cart.lines.isEmpty
                ? null
                : () {
                    notifier.setChannel(OrderChannel.takeaway);
                    widget.onCheckout();
                  },
          ),
        ],
      ),
    );
  }

  Widget _qtyBtn(String label, VoidCallback onTap) {
    return PosTap(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: HasimColors.surface,
          border: Border.all(color: HasimColors.border),
          borderRadius: BorderRadius.circular(HasimRadius.sm),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
      ),
    );
  }

  Widget _money(String label, double value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: bold ? 13 : 11,
              fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            value.toStringAsFixed(2),
            style: TextStyle(
              fontSize: bold ? 13 : 11,
              fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TablePick {
  const _TablePick({required this.id, this.localId});
  final int id;
  final String? localId;
}

class _TablePickerField extends StatelessWidget {
  const _TablePickerField({
    required this.tables,
    required this.selectedId,
    required this.onSelected,
  });

  final List<Map<String, dynamic>> tables;
  final int? selectedId;
  final void Function(int? id, {String? localId}) onSelected;

  String get _label {
    for (final t in tables) {
      if (asInt(t['id'] ?? t['server_id']) == selectedId) {
        return '${t['name']}';
      }
    }
    return 'اختر الطاولة';
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<_TablePick>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'اختر الطاولة',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                ),
              ),
              if (tables.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'لا توجد طاولات محلية. أضف طاولة من الإعدادات.',
                    style: TextStyle(color: HasimColors.muted),
                  ),
                )
              else
                for (final t in tables)
                  PosTap(
                    onTap: () {
                      final id = asInt(t['id'] ?? t['server_id']);
                      if (id == null) return;
                      Navigator.pop(
                        ctx,
                        _TablePick(
                          id: id,
                          localId: t['local_id']?.toString(),
                        ),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      color: asInt(t['id'] ?? t['server_id']) == selectedId
                          ? HasimColors.brandSoft
                          : null,
                      child: Text(
                        '${t['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      onSelected(picked.id, localId: picked.localId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PosTap(
      onTap: () => _open(context),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'الطاولة',
          isDense: true,
          border: OutlineInputBorder(),
          suffixIcon: Icon(Icons.keyboard_arrow_down),
        ),
        child: Text(
          _label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: selectedId == null ? HasimColors.muted : HasimColors.ink,
          ),
        ),
      ),
    );
  }
}

class _OrderTypeChip extends StatelessWidget {
  const _OrderTypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PosTap(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? HasimColors.cta : HasimColors.surface,
          borderRadius: BorderRadius.circular(HasimRadius.sm),
          border: Border.all(
            color: selected ? HasimColors.cta : HasimColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : HasimColors.ink,
          ),
        ),
      ),
    );
  }
}

class _SuccessOrderDialog extends StatelessWidget {
  const _SuccessOrderDialog({
    required this.orderNumber,
    required this.onPrint,
    required this.onContinue,
  });

  final String orderNumber;
  final VoidCallback onPrint;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HasimRadius.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: HasimColors.ctaSoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, color: HasimColors.cta),
            ),
            const SizedBox(height: 12),
            const Text(
              'تم إنشاء الطلب بنجاح',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'رقم الطلب: #$orderNumber',
              style: const TextStyle(color: HasimColors.muted),
            ),
            const SizedBox(height: 18),
            HsPrimaryButton(label: 'طباعة الفاتورة', onPressed: onPrint),
            const SizedBox(height: 8),
            HsOutlineButton(label: 'بدون فاتورة', onPressed: onContinue),
          ],
        ),
      ),
    );
  }
}
