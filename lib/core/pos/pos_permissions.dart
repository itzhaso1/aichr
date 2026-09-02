import 'pos_errors.dart';

/// Business-layer permission keys. UI hiding is never sufficient.
class PosPermissions {
  const PosPermissions._();

  static const pay = 'orders.create';
  static const discount = 'orders.discount';
  static const refund = 'orders.refund';
  static const catalog = 'menu.manage';
  static const shiftOpen = 'shifts.open';
  static const shiftClose = 'shifts.close';
  static const shiftManage = 'shifts.manage';
  static const cashMovement = 'cash.movement';
  static const stockAdjust = 'stock.adjust';
  static const backup = 'workspace.manage';

  static bool allows(Map<String, dynamic>? permissions, String key) {
    if (permissions == null || permissions.isEmpty) return false;
    if (_truthy(permissions[key])) return true;
    if (key == pay) {
      return _truthy(permissions['orders.manage']) ||
          _truthy(permissions['pos.use']);
    }
    if (key == discount) {
      return _truthy(permissions['orders.manage']) ||
          _truthy(permissions['pos.manage']);
    }
    if (key == refund) {
      return _truthy(permissions['orders.manage']) ||
          _truthy(permissions['pos.manage']);
    }
    if (key == catalog) {
      return _truthy(permissions['workspace.manage']);
    }
    if (key == shiftOpen || key == shiftClose) {
      return _truthy(permissions[shiftManage]) ||
          _truthy(permissions['pos.manage']);
    }
    if (key == cashMovement) {
      return _truthy(permissions[shiftManage]) ||
          _truthy(permissions['pos.manage']);
    }
    if (key == stockAdjust) {
      return _truthy(permissions[catalog]) ||
          _truthy(permissions['workspace.manage']);
    }
    return false;
  }

  static void require(Map<String, dynamic>? permissions, String key) {
    if (!allows(permissions, key)) {
      throw const Forbidden();
    }
  }

  static bool _truthy(Object? value) =>
      value == true || value == 1 || value == '1' || value == 'true';
}
