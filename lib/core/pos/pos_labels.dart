/// Labels mirrored from Laravel POS (`PosOrderController::posStatusLabels`).
library;

import 'dart:ui';

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

  static Color statusColor(String? key) => switch (key) {
        'new' => const Color(0xFF2563EB),
        'accepted' => const Color(0xFF059669),
        'preparing' => const Color(0xFFD97706),
        'ready' => const Color(0xFF7C3AED),
        'delivered' => const Color(0xFF0F766E),
        'completed' => const Color(0xFF334155),
        'cancelled' => const Color(0xFFDC2626),
        _ => const Color(0xFF64748B),
      };

  static Color statusSoft(String? key) => switch (key) {
        'new' => const Color(0xFFDBEAFE),
        'accepted' => const Color(0xFFD1FAE5),
        'preparing' => const Color(0xFFFEF3C7),
        'ready' => const Color(0xFFEDE9FE),
        'delivered' => const Color(0xFFCCFBF1),
        'completed' => const Color(0xFFE2E8F0),
        'cancelled' => const Color(0xFFFFE4E6),
        _ => const Color(0xFFF1F5F9),
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
