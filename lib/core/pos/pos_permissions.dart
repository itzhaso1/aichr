import 'pos_errors.dart';
import '../permissions/staff_permissions.dart';

/// Business-layer permission keys. UI hiding is never sufficient.
class PosPermissions {
  const PosPermissions._();

  static const pay = StaffPermissions.ordersCreate;
  static const discount = StaffPermissions.ordersDiscount;
  static const refund = StaffPermissions.ordersRefund;
  static const catalog = StaffPermissions.menuManage;
  static const tables = StaffPermissions.tablesManage;
  static const tablesCreate = StaffPermissions.tablesCreate;
  static const tablesEdit = StaffPermissions.tablesEdit;
  static const tablesDelete = StaffPermissions.tablesDelete;
  static const invoicesView = StaffPermissions.invoicesView;
  static const invoicesCreate = StaffPermissions.invoicesCreate;
  static const invoicesEdit = StaffPermissions.invoicesEdit;
  static const invoicesDelete = StaffPermissions.invoicesDelete;
  static const kitchen = StaffPermissions.kitchenUse;
  static const reports = StaffPermissions.reportsView;
  static const users = StaffPermissions.usersManage;
  static const shiftOpen = StaffPermissions.shiftsOpen;
  static const shiftClose = StaffPermissions.shiftsClose;
  static const shiftManage = StaffPermissions.shiftsManage;
  static const cashMovement = StaffPermissions.cashMovement;
  static const stockAdjust = StaffPermissions.stockAdjust;
  static const backup = StaffPermissions.workspaceManage;

  static bool allows(Map<String, dynamic>? permissions, String key) {
    if (StaffPermissions.can(permissions, key)) return true;
    if (permissions == null || permissions.isEmpty) return false;
    if (key == pay) {
      return StaffPermissions.can(permissions, StaffPermissions.ordersManage) ||
          StaffPermissions.can(permissions, StaffPermissions.posUse) ||
          StaffPermissions.can(permissions, StaffPermissions.invoicesCreate);
    }
    if (key == discount) {
      return StaffPermissions.can(permissions, StaffPermissions.ordersManage) ||
          StaffPermissions.can(permissions, StaffPermissions.posManage);
    }
    if (key == refund) {
      return StaffPermissions.can(permissions, StaffPermissions.ordersManage) ||
          StaffPermissions.can(permissions, StaffPermissions.posManage);
    }
    if (key == catalog) {
      return false;
    }
    if (key == tables ||
        key == tablesCreate ||
        key == tablesEdit ||
        key == tablesDelete) {
      return StaffPermissions.can(permissions, StaffPermissions.tablesManage);
    }
    if (key == invoicesEdit || key == invoicesDelete) {
      return false;
    }
    if (key == invoicesView) {
      return StaffPermissions.can(permissions, StaffPermissions.posUse);
    }
    if (key == invoicesCreate) {
      return StaffPermissions.can(permissions, StaffPermissions.ordersCreate);
    }
    if (key == shiftOpen || key == shiftClose) {
      return StaffPermissions.can(permissions, shiftManage) ||
          StaffPermissions.can(permissions, StaffPermissions.posManage);
    }
    if (key == cashMovement) {
      return StaffPermissions.can(permissions, shiftManage) ||
          StaffPermissions.can(permissions, StaffPermissions.posManage);
    }
    if (key == stockAdjust) {
      return StaffPermissions.can(permissions, catalog);
    }
    if (key == kitchen) {
      return StaffPermissions.can(permissions, StaffPermissions.ordersManage) ||
          StaffPermissions.can(permissions, StaffPermissions.posUse);
    }
    if (key == reports) {
      return false;
    }
    return false;
  }

  static void require(Map<String, dynamic>? permissions, String key) {
    if (!allows(permissions, key)) {
      throw const Forbidden();
    }
  }
}
