/// Stable id for a table-session order snapshot (SQLite row or payload).
String tableOrderIdentity(Map<String, dynamic> order) {
  for (final key in [
    'local_id',
    'invoice_local_id',
    'client_reference',
    'id',
  ]) {
    final value = '${order[key] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
  }
  final number = '${order['order_number'] ?? ''}'.trim();
  if (number.isNotEmpty) return 'num:$number';
  return '';
}

bool isCancelledTableOrder(Map<String, dynamic> order) =>
    '${order['pos_status'] ?? ''}' == 'cancelled';

/// Cashier occupy snapshots are paid/invoiced and must survive later adds.
bool isPaidTableOrder(Map<String, dynamic> order) {
  final status = '${order['pos_status'] ?? ''}';
  final pay = '${order['payment_status'] ?? ''}';
  if (pay == 'paid' || status == 'completed') return true;
  return '${order['invoice_local_id'] ?? ''}'.trim().isNotEmpty;
}

/// Append live (usually unpaid) orders onto existing session snapshots.
/// Never drops paid/invoiced rows from [sessionOrders].
List<Map<String, dynamic>> mergeTableSessionOrders({
  required List<Map<String, dynamic>> sessionOrders,
  required List<Map<String, dynamic>> liveOrders,
}) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  final liveKeys = {for (final order in liveOrders) tableOrderIdentity(order)}
    ..removeWhere((key) => key.isEmpty);

  void add(Map<String, dynamic> order) {
    if (isCancelledTableOrder(order)) return;
    var key = tableOrderIdentity(order);
    if (key.isEmpty) {
      key = 'anon:${out.length}:${order['total_amount']}';
    }
    if (!seen.add(key)) return;
    out.add(Map<String, dynamic>.from(order));
  }

  for (final order in sessionOrders) {
    final key = tableOrderIdentity(order);
    if (key.isNotEmpty && liveKeys.contains(key)) {
      continue;
    }
    if (isPaidTableOrder(order) || liveOrders.isEmpty) {
      add(order);
    }
  }
  for (final order in liveOrders) {
    add(order);
  }
  return out;
}

/// True when a SQLite order belongs to the currently open table session.
bool isOrderInOpenTableSession({
  required String posStatus,
  required String paymentStatus,
  required DateTime createdAt,
  DateTime? openedAt,
}) {
  if (posStatus == 'cancelled') return false;
  final unpaid = paymentStatus != 'paid' && posStatus != 'completed';
  if (unpaid) return true;
  if (openedAt == null) return false;
  final start = openedAt.toUtc().subtract(const Duration(minutes: 5));
  return !createdAt.toUtc().isBefore(start);
}

bool looksLikeFlatOrderLines(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return false;
  return rows.every((row) {
    if (row['items'] is List) return false;
    return row.containsKey('item_name') ||
        row.containsKey('quantity') ||
        row.containsKey('unit_price') ||
        row.containsKey('product_name');
  });
}
