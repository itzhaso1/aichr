import 'dart:convert';

import 'package:drift/drift.dart';

import '../local_db/app_database.dart';
import '../pos/domain/pricing_service.dart';
import '../util/json_numbers.dart';

/// Local invoices + daily report aggregates from SQLite (offline-capable).
class LocalFinanceRepository {
  LocalFinanceRepository(this._db);

  final AppDatabase _db;

  Future<List<Map<String, dynamic>>> listInvoices({
    required int workspaceId,
    DateTime? onDate,
  }) async {
    if (workspaceId <= 0) return const [];
    final rows = await (_db.select(_db.localInvoices)
          ..where((t) => t.workspaceId.equals(workspaceId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (onDate != null && !_sameDay(row.createdAt, onDate)) continue;
      out.add(_invoiceToMap(row));
    }
    return out;
  }

  Future<Map<String, dynamic>?> getInvoice({
    required int workspaceId,
    required String localId,
  }) async {
    final row = await (_db.select(_db.localInvoices)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) & t.localId.equals(localId)))
        .getSingleOrNull();
    if (row == null) return null;
    return _invoiceToMap(row);
  }

  Future<Map<String, dynamic>?> getInvoiceByServerId({
    required int workspaceId,
    required int serverId,
  }) async {
    final row = await (_db.select(_db.localInvoices)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) & t.serverId.equals(serverId)))
        .getSingleOrNull();
    if (row == null) return null;
    return _invoiceToMap(row);
  }

  /// Build a daily report payload compatible with DailyReportsPanel.
  Future<Map<String, dynamic>> buildDailyReport({
    required int workspaceId,
    required DateTime date,
  }) async {
    final invoices = await listInvoices(workspaceId: workspaceId, onDate: date);
    final orders = await (_db.select(_db.localOrders)
          ..where((t) => t.workspaceId.equals(workspaceId)))
        .get();
    final dayOrders = [
      for (final o in orders)
        if (_sameDay(o.createdAt, date) || _sameDay(o.updatedAt, date)) o,
    ];
    final payments = await (_db.select(_db.localPayments)
          ..where((t) => t.workspaceId.equals(workspaceId)))
        .get();
    final dayPayments = [
      for (final p in payments)
        if (_sameDay(p.createdAt, date)) p,
    ];

    var salesTotal = 0.0;
    var invoicesCount = 0;
    for (final inv in invoices) {
      salesTotal += asDoubleOr(inv['total_amount']);
      invoicesCount++;
    }
    if (salesTotal <= 0) {
      for (final o in dayOrders) {
        if (o.posStatus == 'cancelled') continue;
        if (o.paymentStatus == 'paid' || o.posStatus == 'completed') {
          salesTotal += Money.fromCents(o.totalAmount);
        }
      }
    }

    final byMethod = <String, double>{};
    for (final p in dayPayments) {
      byMethod[p.method] =
          (byMethod[p.method] ?? 0) + Money.fromCents(p.amount);
    }
    if (byMethod.isEmpty) {
      for (final inv in invoices) {
        final method = '${inv['payment_method'] ?? 'cash'}';
        byMethod[method] =
            (byMethod[method] ?? 0) + asDoubleOr(inv['total_amount']);
      }
    }

    final closedOrders = <Map<String, dynamic>>[];
    final allOrders = <Map<String, dynamic>>[];
    var openCount = 0;
    var tableSales = 0.0;
    var takeawaySales = 0.0;
    for (final o in dayOrders) {
      final map = {
        'id': o.serverId ?? o.localId,
        'order_number': o.serverId?.toString() ?? 'محلي',
        'order_type': o.orderType,
        'pos_status': o.posStatus,
        'payment_status': o.paymentStatus,
        'total_amount': Money.fromCents(o.totalAmount),
        'created_at': o.createdAt.toIso8601String(),
      };
      allOrders.add(map);
      if (o.posStatus == 'cancelled') continue;
      if (o.paymentStatus == 'paid' || o.posStatus == 'completed') {
        closedOrders.add(map);
        if (o.orderType == 'table') {
          tableSales += Money.fromCents(o.totalAmount);
        } else {
          takeawaySales += Money.fromCents(o.totalAmount);
        }
      } else {
        openCount++;
      }
    }

    final hourBuckets = <int, double>{};
    for (final inv in invoices) {
      final closedAt = inv['closed_at'] ?? inv['created_at'];
      final at = DateTime.tryParse('$closedAt')?.toLocal() ?? date;
      hourBuckets[at.hour] =
          (hourBuckets[at.hour] ?? 0) + asDoubleOr(inv['total_amount']);
    }

    return {
      'date':
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      'source': 'local_sqlite',
      'summary': {
        'invoice_sales_total': salesTotal,
        'invoices_total': salesTotal,
        'invoices_count': invoicesCount,
        'orders_count': dayOrders.length,
        'closed_orders_count': closedOrders.length,
        'open_orders_count': openCount,
        'table_sales_total': tableSales,
        'takeaway_sales_total': takeawaySales,
      },
      'channel_stats': {
        'table': dayOrders.where((o) => o.orderType == 'table').length,
        'takeaway': dayOrders.where((o) => o.orderType == 'takeaway').length,
        'delivery': dayOrders.where((o) => o.orderType == 'delivery').length,
      },
      'payment_methods': [
        for (final e in byMethod.entries)
          {
            'method': e.key,
            'total': e.value,
            'orders_count': 1,
            'count': 1,
          },
      ],
      'invoices': invoices,
      'closed_orders': closedOrders,
      'all_orders': allOrders,
      'sales_by_hour': [
        for (final e in hourBuckets.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
          {'hour': e.key, 'sales_total': e.value, 'total_sales': e.value},
      ],
      'top_items': const [],
      'quantity_by_type': const [],
      'customer_summary': const [],
      'recent_operations': [
        for (final inv in invoices.take(20))
          {
            'label': 'فاتورة ${inv['invoice_number']}',
            'total': asDoubleOr(inv['total_amount']),
            'at': inv['closed_at'] ?? inv['created_at'],
          },
      ],
    };
  }

  /// Never spread raw payloadJson — legacy rows may store money as strings and
  /// that previously crashed UI with `String is not a subtype of num`.
  Map<String, dynamic> _invoiceToMap(LocalInvoice row) {
    final payload = _safeMap(row.payloadJson);
    final items = <Map<String, dynamic>>[];
    for (final raw in asMapList(payload['items'])) {
      items.add({
        'item_name':
            '${raw['item_name'] ?? raw['product_name'] ?? raw['name'] ?? 'صنف'}',
        'quantity': asIntOr(raw['quantity'], 1),
        'unit_price': asDoubleOr(raw['unit_price']),
        'tax_amount': asDoubleOr(raw['tax_amount']),
        'total_amount': asDoubleOr(
          raw['total_amount'] ?? raw['total'],
        ),
        'discount_amount': asDoubleOr(raw['discount_amount']),
      });
    }

    final table = payload['table'];
    final tableOut = table is Map
        ? {
            'id': table['id'],
            'name': nestedName(table, fallback: ''),
          }
        : (table != null ? {'name': '$table'} : null);

    return {
      'id': row.serverId ?? row.localId,
      'local_id': row.localId,
      'server_id': row.serverId,
      'invoice_number':
          row.invoiceNumber ??
          row.localInvoiceNumber ??
          payload['invoice_number']?.toString() ??
          row.localId,
      'order_local_id': row.orderLocalId ?? payload['order_local_id'],
      'subtotal': Money.fromCents(row.subtotal),
      'discount_amount': Money.fromCents(row.discountAmount),
      'tax_amount': Money.fromCents(row.taxAmount),
      'total_amount': Money.fromCents(row.totalAmount),
      'payment_method': payload['payment_method']?.toString(),
      'closed_at':
          payload['closed_at']?.toString() ?? row.createdAt.toIso8601String(),
      'created_at': row.createdAt.toIso8601String(),
      'items': items,
      if (tableOut != null) 'table': tableOut,
      'store_name': payload['store_name']?.toString(),
      'sync_status': row.syncStatus,
      'is_local': row.serverId == null,
      'status': row.status,
    };
  }

  bool _sameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  Map<String, dynamic> _safeMap(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return const {};
  }
}
