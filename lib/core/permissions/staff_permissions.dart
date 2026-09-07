/// Granular staff ACL. Role defaults are a starting point; admin overrides
/// are stored per user and merged on login. UI hiding is never sufficient —
/// callers must [require] these keys in services.
class StaffPermissions {
  const StaffPermissions._();

  static const posUse = 'pos.use';
  static const posManage = 'pos.manage';
  static const ordersCreate = 'orders.create';
  static const ordersManage = 'orders.manage';
  static const ordersDiscount = 'orders.discount';
  static const ordersRefund = 'orders.refund';
  static const invoicesView = 'invoices.view';
  static const invoicesCreate = 'invoices.create';
  static const invoicesEdit = 'invoices.edit';
  static const invoicesDelete = 'invoices.delete';
  static const tablesView = 'tables.view';
  static const tablesCreate = 'tables.create';
  static const tablesEdit = 'tables.edit';
  static const tablesDelete = 'tables.delete';
  static const tablesManage = 'tables.manage';
  static const kitchenUse = 'kitchen.use';
  static const reportsView = 'reports.view';
  static const menuManage = 'menu.manage';
  static const shiftsOpen = 'shifts.open';
  static const shiftsClose = 'shifts.close';
  static const shiftsManage = 'shifts.manage';
  static const cashMovement = 'cash.movement';
  static const stockAdjust = 'stock.adjust';
  static const usersManage = 'users.manage';
  static const workspaceManage = 'workspace.manage';

  /// Admin checklist: label + key. Mutations that stay admin-only by default
  /// are invoices.edit/delete and tables.create/edit/delete.
  static const catalog = <({String key, String labelAr, String group})>[
    (key: posUse, labelAr: 'استخدام الكاشير', group: 'الكاشير'),
    (key: ordersCreate, labelAr: 'إنشاء الطلبات / إضافة فاتورة بيع', group: 'الكاشير'),
    (key: ordersDiscount, labelAr: 'تطبيق خصم', group: 'الكاشير'),
    (key: ordersRefund, labelAr: 'مرتجعات', group: 'الكاشير'),
    (key: ordersManage, labelAr: 'إدارة حالة الطلبات', group: 'الكاشير'),
    (key: invoicesView, labelAr: 'عرض الفواتير', group: 'الفواتير'),
    (key: invoicesCreate, labelAr: 'إضافة فاتورة', group: 'الفواتير'),
    (key: invoicesEdit, labelAr: 'تعديل الفواتير', group: 'الفواتير'),
    (key: invoicesDelete, labelAr: 'حذف الفواتير', group: 'الفواتير'),
    (key: tablesView, labelAr: 'عرض الطاولات', group: 'الطاولات'),
    (key: tablesCreate, labelAr: 'إضافة طاولات', group: 'الطاولات'),
    (key: tablesEdit, labelAr: 'تعديل الطاولات', group: 'الطاولات'),
    (key: tablesDelete, labelAr: 'حذف الطاولات', group: 'الطاولات'),
    (key: kitchenUse, labelAr: 'الدخول إلى صفحة المطبخ', group: 'الصفحات'),
    (key: reportsView, labelAr: 'الدخول إلى صفحة التقارير', group: 'الصفحات'),
    (key: menuManage, labelAr: 'إدارة الأصناف', group: 'أخرى'),
    (key: shiftsOpen, labelAr: 'فتح وردية', group: 'أخرى'),
    (key: shiftsClose, labelAr: 'إغلاق وردية', group: 'أخرى'),
    (key: cashMovement, labelAr: 'حركة الصندوق', group: 'أخرى'),
    (key: stockAdjust, labelAr: 'تعديل المخزون', group: 'أخرى'),
    (key: usersManage, labelAr: 'إدارة المستخدمين والصلاحيات', group: 'أخرى'),
    (key: workspaceManage, labelAr: 'صلاحيات المدير الكاملة', group: 'أخرى'),
  ];

  static const adminDefaults = {
    posUse: true,
    posManage: true,
    ordersCreate: true,
    ordersManage: true,
    ordersDiscount: true,
    ordersRefund: true,
    invoicesView: true,
    invoicesCreate: true,
    invoicesEdit: true,
    invoicesDelete: true,
    tablesView: true,
    tablesCreate: true,
    tablesEdit: true,
    tablesDelete: true,
    tablesManage: true,
    kitchenUse: true,
    reportsView: true,
    menuManage: true,
    shiftsOpen: true,
    shiftsClose: true,
    shiftsManage: true,
    cashMovement: true,
    stockAdjust: true,
    usersManage: true,
    workspaceManage: true,
  };

  static const cashierDefaults = {
    posUse: true,
    ordersCreate: true,
    invoicesView: true,
    invoicesCreate: true,
    tablesView: true,
    shiftsOpen: true,
  };

  static const chefDefaults = {
    kitchenUse: true,
    ordersManage: true,
  };

  static Map<String, dynamic> defaultsForRole(String? role) {
    final value = (role ?? '').trim().toLowerCase();
    return switch (value) {
      'admin' => Map<String, dynamic>.from(adminDefaults),
      'manager' => {
          ...adminDefaults,
          workspaceManage: false,
          posManage: false,
          usersManage: false,
        },
      'chef' || 'kitchen' => Map<String, dynamic>.from(chefDefaults),
      _ => Map<String, dynamic>.from(cashierDefaults),
    };
  }

  static bool truthy(Object? value) =>
      value == true || value == 1 || value == '1' || value == 'true';

  static bool can(Map<String, dynamic>? permissions, String key) {
    if (permissions == null || permissions.isEmpty) return false;
    if (truthy(permissions[key])) return true;
    if (truthy(permissions[workspaceManage]) && key != workspaceManage) {
      return true;
    }
    return false;
  }

  /// Role defaults overlaid with saved per-user flags. Explicit `false`
  /// removes a default; missing keys keep the role default.
  static Map<String, dynamic> merge({
    required String? role,
    Map<String, dynamic>? stored,
  }) {
    final merged = defaultsForRole(role);
    if (stored == null || stored.isEmpty) return merged;
    stored.forEach((key, value) {
      merged[key] = truthy(value);
    });
    return merged;
  }
}
