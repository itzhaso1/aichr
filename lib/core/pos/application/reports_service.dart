import 'dart:convert';

import 'package:drift/drift.dart';

import '../../local_db/app_database.dart';
import '../domain/pricing_service.dart';

class LocalReportsService {
  LocalReportsService(this._db);

  final AppDatabase _db;

  static const recentInvoiceLimit = 100;

  Future<Map<String, dynamic>> daily({
    required int workspaceId,
    required DateTime date,
  }) async {
    if (workspaceId <= 0) {
      return _empty(date);
    }

    // Dart calendar-day filters only. SQL DateTime binds have stalled the
    // reports tab on "جاري تحميل التقرير…" in offline SQLite builds.
    final invoices = await (_db.select(_db.localInvoices)
          ..where((t) => t.workspaceId.equals(workspaceId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    final dayInvoices = [
      for (final row in invoices)
        if (_sameCalendarDay(row.createdAt, date)) row,
    ];

    final orders = await (_db.select(_db.localOrders)
          ..where((t) => t.workspaceId.equals(workspaceId)))
        .get();
    final dayOrders = [
      for (final row in orders)
        if (_sameCalendarDay(row.createdAt, date) ||
            _sameCalendarDay(row.updatedAt, date))
          row,
    ];

    final payments = await (_db.select(_db.localPayments)
          ..where((t) => t.workspaceId.equals(workspaceId)))
        .get();
    final dayPayments = [
      for (final row in payments)
        if (_sameCalendarDay(row.createdAt, date)) row,
    ];

    final returns = await (_db.select(_db.localReturns)
          ..where((t) => t.workspaceId.equals(workspaceId)))
        .get();
    final dayReturns = [
      for (final row in returns)
        if (_sameCalendarDay(row.createdAt, date)) row,
    ];

    var invoicesCount = dayInvoices.length;
    var subtotalCents = dayInvoices.fold<int>(0, (s, r) => s + r.subtotal);
    var discountCents =
        dayInvoices.fold<int>(0, (s, r) => s + r.discountAmount);
    var taxCents = dayInvoices.fold<int>(0, (s, r) => s + r.taxAmount);
    var grossCents = 0;
    for (final row in dayInvoices) {
      final fromCol = row.totalAmount;
      final fromPayload = _payloadCents(row.payloadJson, 'total_amount');
      grossCents += fromCol > 0 ? fromCol : fromPayload;
      if (row.subtotal <= 0) {
        subtotalCents += _payloadCents(row.payloadJson, 'subtotal');
      }
    }

    final liveOrders = [
      for (final o in dayOrders)
        if (o.posStatus != 'cancelled') o,
    ];
    final paidOrders = [
      for (final o in liveOrders)
        if (o.paymentStatus == 'paid' || o.posStatus == 'completed') o,
    ];
    final openOrders = [
      for (final o in liveOrders)
        if (o.paymentStatus != 'paid' && o.posStatus != 'completed') o,
    ];

    if (grossCents <= 0 && paidOrders.isNotEmpty) {
      subtotalCents = paidOrders.fold<int>(0, (s, r) => s + r.subtotal);
      discountCents = paidOrders.fold<int>(0, (s, r) => s + r.discountAmount);
      taxCents = paidOrders.fold<int>(0, (s, r) => s + r.taxAmount);
      grossCents = paidOrders.fold<int>(0, (s, r) => s + r.totalAmount);
    }

    final byMethod = <String, ({int count, int total})>{};
    for (final p in dayPayments) {
      final prev = byMethod[p.method];
      byMethod[p.method] = (
        count: (prev?.count ?? 0) + 1,
        total: (prev?.total ?? 0) + p.amount,
      );
    }

    var returnCount = 0;
    var returnCents = 0;
    for (final r in dayReturns) {
      returnCount++;
      returnCents += r.refundAmount;
    }

    final paidIds = {for (final o in paidOrders) o.localId};
    final items = paidIds.isEmpty
        ? const <LocalOrderItem>[]
        : await (_db.select(_db.localOrderItems)
              ..where(
                (t) =>
                    t.workspaceId.equals(workspaceId) &
                    t.isRemoved.equals(false),
              ))
            .get();

    var cogsCents = 0;
    final topAgg = <String, ({int qty, int rev})>{};
    for (final item in items) {
      if (!paidIds.contains(item.orderLocalId)) continue;
      cogsCents += item.costSnapshot * item.quantity;
      final prev = topAgg[item.name];
      topAgg[item.name] = (
        qty: (prev?.qty ?? 0) + item.quantity,
        rev: (prev?.rev ?? 0) + item.totalAmount,
      );
    }
    final topSorted = topAgg.entries.toList()
      ..sort((a, b) => b.value.qty.compareTo(a.value.qty));

    final netCents = grossCents - returnCents;
    final invoiceMaps = [
      for (final row in dayInvoices.take(recentInvoiceLimit))
        {
          'id': row.localId,
          'local_id': row.localId,
          'invoice_number':
              row.localInvoiceNumber ?? row.invoiceNumber ?? row.localId,
          'total_amount': Money.fromCents(
            row.totalAmount > 0
                ? row.totalAmount
                : _payloadCents(row.payloadJson, 'total_amount'),
          ),
          'tax_amount': Money.fromCents(row.taxAmount),
          'discount_amount': Money.fromCents(row.discountAmount),
          'created_at': row.createdAt.toIso8601String(),
        },
    ];

    return {
      'date':
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      'source': 'local_sqlite',
      'summary': {
        'invoice_sales_total': Money.fromCents(grossCents),
        'invoices_total': Money.fromCents(grossCents),
        'invoices_count': invoicesCount,
        'orders_count': liveOrders.length,
        'open_orders_count': openOrders.length,
        'completed_orders_count': paidOrders.length,
        'cancelled_orders_count': dayOrders
            .where((o) => o.posStatus == 'cancelled')
            .length,
        'paid_orders_count': paidOrders.length,
        'unpaid_orders_count': openOrders.length,
        'table_orders_count':
            liveOrders.where((o) => o.orderType == 'table').length,
        'takeaway_orders_count':
            liveOrders.where((o) => o.orderType == 'takeaway').length,
        'delivery_orders_count':
            liveOrders.where((o) => o.orderType == 'delivery').length,
        'subtotal': Money.fromCents(subtotalCents),
        'discount_total': Money.fromCents(discountCents),
        'tax_total': Money.fromCents(taxCents),
        'grand_total': Money.fromCents(netCents),
        'gross_sales': Money.fromCents(grossCents),
        'net_sales': Money.fromCents(netCents),
        'gross_profit': Money.fromCents(netCents - cogsCents),
        'return_count': returnCount,
        'return_amount': Money.fromCents(returnCents),
      },
      'channel_stats': {
        'table': liveOrders.where((o) => o.orderType == 'table').length,
        'takeaway': liveOrders.where((o) => o.orderType == 'takeaway').length,
        'delivery': liveOrders.where((o) => o.orderType == 'delivery').length,
      },
      'payment_methods': [
        for (final e in byMethod.entries)
          {
            'method': e.key,
            'total': Money.fromCents(e.value.total),
            'count': e.value.count,
          },
      ],
      'top_items': [
        for (final e in topSorted.take(20))
          {
            'product_name': e.key,
            'quantity': e.value.qty,
            'sales': Money.fromCents(e.value.rev),
          },
      ],
      'invoices': invoiceMaps,
    };
  }

  Map<String, dynamic> _empty(DateTime date) {
    return {
      'date':
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      'source': 'local_sqlite',
      'summary': const {
        'invoice_sales_total': 0,
        'invoices_total': 0,
        'invoices_count': 0,
        'orders_count': 0,
      },
      'channel_stats': const {},
      'payment_methods': const [],
      'top_items': const [],
      'invoices': const [],
    };
  }

  int _payloadCents(String raw, String key) {
    if (raw.isEmpty) return 0;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return 0;
      final map = Map<String, dynamic>.from(decoded);
      return Money.toCents(map[key] ?? map['total']);
    } catch (_) {
      return 0;
    }
  }

  bool _sameCalendarDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  Future<Map<String, dynamic>> stockSnapshot(int workspaceId) async {
    final products =
        await (_db.select(_db.localProducts)..where(
              (t) =>
                  t.workspaceId.equals(workspaceId) & t.isDeleted.equals(false),
            ))
            .get();
    return {
      'products': [
        for (final p in products)
          {
            'local_id': p.localId,
            'name': p.name,
            'stock': p.stock,
            'track_stock': p.trackStock,
          },
      ],
    };
  }
}
