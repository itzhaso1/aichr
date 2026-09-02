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
        'takeaway' => 'خارجي',
        _ => 'خارجي',
      };

  static String tableStatus(String? status) => switch (status) {
        'occupied' => 'مشغولة',
        'reserved' => 'محجوزة',
        'cleaning' => 'تنظيف',
        'closed' => 'مغلقة',
        _ => 'فارغة',
      };
}
