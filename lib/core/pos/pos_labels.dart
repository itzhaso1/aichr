/// Labels mirrored from Laravel POS (`PosOrderController::posStatusLabels`).
library;

abstract final class PosLabels {
  static const Map<String, String> orderStatus = {
    'new': 'جديد',
    'accepted': 'مقبول',
    'preparing': 'قيد التحضير',
    'ready': 'جاهز',
    'delivered': 'تم التسليم',
    'completed': 'مكتمل',
    'cancelled': 'ملغي',
  };

  static String status(String? key) =>
      orderStatus[key] ?? (key == null || key.isEmpty ? '—' : key);

  static String orderType(String? type) => switch (type) {
        'table' => 'طاولة',
        'delivery' => 'توصيل',
        'takeaway' => 'طلب خارجي',
        _ => 'طلب خارجي',
      };

  /// Kitchen ticket title: table name, or the takeaway/delivery channel.
  static String kitchenHeading({
    String? orderType,
    String? tableName,
  }) {
    switch (orderType) {
      case 'delivery':
        return 'توصيل';
      case 'takeaway':
        return 'طلب خارجي';
      default:
        final table = tableName?.trim() ?? '';
        return table.isEmpty ? 'طاولة' : table;
    }
  }

  static String tableStatus(String? status) => switch (status) {
        'occupied' => 'مشغولة',
        'reserved' => 'محجوزة',
        'cleaning' => 'تنظيف',
        'closed' => 'مغلقة',
        _ => 'فارغة',
      };
}
