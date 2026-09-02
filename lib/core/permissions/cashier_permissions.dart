/// Cashier permission helpers — Laravel bootstrap `permissions` is source of truth.
library;

class CashierPermissions {
  const CashierPermissions._();

  static bool can(Map<String, dynamic>? permissions, String key) {
    if (permissions == null || permissions.isEmpty) return false;
    final value = permissions[key];
    // Accept JSON bool and common truthy encodings from serializers.
    return value == true || value == 1 || value == '1' || value == 'true';
  }

  /// Align with AuthorizesCashier / PosBaseController: not via `pos.manage` alone.
  static bool canManageTables(Map<String, dynamic>? p) =>
      can(p, 'tables.manage') || can(p, 'workspace.manage');

  /// Align with AuthorizesCashier / PosBaseController: not via `pos.manage` alone.
  static bool canManageMenu(Map<String, dynamic>? p) =>
      can(p, 'menu.manage') || can(p, 'workspace.manage');

  static bool canCreateOrders(Map<String, dynamic>? p) =>
      can(p, 'orders.create') || can(p, 'orders.manage') || can(p, 'pos.use');

  static bool canDiscount(Map<String, dynamic>? p) =>
      can(p, 'orders.discount') || can(p, 'orders.manage') || can(p, 'pos.manage');

  static bool canRefund(Map<String, dynamic>? p) =>
      can(p, 'orders.refund') || can(p, 'orders.manage') || can(p, 'pos.manage');

  static bool canViewReports(Map<String, dynamic>? p) =>
      can(p, 'reports.view') ||
      can(p, 'pos.manage') ||
      can(p, 'orders.manage') ||
      can(p, 'workspace.manage');

  static bool canOpenShift(Map<String, dynamic>? p) =>
      can(p, 'shifts.open') || can(p, 'shifts.manage') || can(p, 'pos.manage');

  static bool canCloseShift(Map<String, dynamic>? p) =>
      can(p, 'shifts.close') || can(p, 'shifts.manage') || can(p, 'pos.manage');

  static bool canMoveCash(Map<String, dynamic>? p) =>
      can(p, 'cash.movement') || can(p, 'shifts.manage') || can(p, 'pos.manage');

  static bool canAdjustStock(Map<String, dynamic>? p) =>
      can(p, 'stock.adjust') || can(p, 'menu.manage') || can(p, 'workspace.manage');

  static bool canBackup(Map<String, dynamic>? p) => can(p, 'workspace.manage');

  /// Prefer bootstrap snapshot; fall back to auth session permissions.
  static Map<String, dynamic> resolve(
    Map<String, dynamic>? bootstrap,
    Map<String, dynamic>? session,
  ) {
    if (bootstrap != null && bootstrap.isNotEmpty) return bootstrap;
    if (session != null && session.isNotEmpty) return session;
    return const {};
  }
}
