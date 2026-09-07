/// Cashier permission helpers. Granular keys live in [StaffPermissions].
/// UI hiding is never sufficient — services must also [PosPermissions.require].
library;

import 'staff_permissions.dart';

class CashierPermissions {
  const CashierPermissions._();

  static bool can(Map<String, dynamic>? permissions, String key) =>
      StaffPermissions.can(permissions, key);

  static bool canManageTables(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.tablesManage) ||
      can(p, StaffPermissions.tablesCreate) ||
      can(p, StaffPermissions.tablesEdit) ||
      can(p, StaffPermissions.tablesDelete);

  static bool canViewTables(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.tablesView) ||
      can(p, StaffPermissions.tablesManage) ||
      can(p, StaffPermissions.posUse);

  static bool canCreateTables(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.tablesCreate) ||
      can(p, StaffPermissions.tablesManage);

  static bool canEditTables(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.tablesEdit) ||
      can(p, StaffPermissions.tablesManage);

  static bool canDeleteTables(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.tablesDelete) ||
      can(p, StaffPermissions.tablesManage);

  static bool canManageMenu(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.menuManage);

  static bool canCreateOrders(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.ordersCreate) ||
      can(p, StaffPermissions.ordersManage) ||
      can(p, StaffPermissions.posUse);

  static bool canDiscount(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.ordersDiscount) ||
      can(p, StaffPermissions.ordersManage) ||
      can(p, StaffPermissions.posManage);

  static bool canRefund(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.ordersRefund) ||
      can(p, StaffPermissions.ordersManage) ||
      can(p, StaffPermissions.posManage);

  static bool canViewReports(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.reportsView);

  static bool canUseKitchen(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.kitchenUse);

  static bool canViewInvoices(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.invoicesView) ||
      can(p, StaffPermissions.posUse);

  static bool canCreateInvoices(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.invoicesCreate) ||
      can(p, StaffPermissions.ordersCreate);

  static bool canEditInvoices(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.invoicesEdit);

  static bool canDeleteInvoices(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.invoicesDelete);

  static bool canOpenShift(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.shiftsOpen) ||
      can(p, StaffPermissions.shiftsManage) ||
      can(p, StaffPermissions.posManage);

  static bool canCloseShift(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.shiftsClose) ||
      can(p, StaffPermissions.shiftsManage) ||
      can(p, StaffPermissions.posManage);

  static bool canMoveCash(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.cashMovement) ||
      can(p, StaffPermissions.shiftsManage) ||
      can(p, StaffPermissions.posManage);

  static bool canAdjustStock(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.stockAdjust) ||
      can(p, StaffPermissions.menuManage);

  static bool canBackup(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.workspaceManage);

  static bool canManageUsers(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.usersManage) ||
      can(p, StaffPermissions.workspaceManage);

  static bool canUsePos(Map<String, dynamic>? p) =>
      can(p, StaffPermissions.posUse);

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
