import 'dart:convert';

import 'package:drift/drift.dart';

import '../local_db/app_database.dart';
import '../pos/domain/pricing_service.dart';
import '../util/json_numbers.dart';

/// Local invoices + daily report aggregates from SQLite (offline-capable).
class LocalFinanceRepository {
  LocalFinanceRepository(this._db);

  final AppDatabase _db;

  Future<List<LocalInvoice>> _queryRows({int? workspaceId}) {
    final query = _db.select(_db.localInvoices)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (workspaceId != null && workspaceId > 0) {
      query.where((t) => t.workspaceId.equals(workspaceId));
    }
    return query.get();
  }

  Future<List<Map<String, dynamic>>> listInvoices({
    int? workspaceId,
    DateTime? onDate,
    bool fallbackAllWorkspaces = false,
  }) async {
    var rows = List<LocalInvoice>.from(
      await _queryRows(workspaceId: workspaceId),
    );
    if (fallbackAllWorkspaces) {
      final all = await _queryRows();
      if (all.length > rows.length) {
        final seen = {for (final row in rows) row.localId};
        for (final row in all) {
          if (seen.add(row.localId)) rows.add(row);
        }
        rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }
    }
    if (onDate != null) {
      final day = [
        for (final row in rows)
          if (_sameDay(row.createdAt, onDate)) row,
      ];
      if (day.isNotEmpty) {
        return _mapsFor(day);
      }
      if (!fallbackAllWorkspaces) return const [];
    }
    return _mapsFor(rows);
  }

  List<Map<String, dynamic>> _mapsFor(List<LocalInvoice> rows) {
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        out.add(_invoiceToMap(row));
      } catch (_) {
        out.add({
          'id': row.localId,
          'local_id': row.localId,
          'invoice_number':
              row.invoiceNumber ?? row.localInvoiceNumber ?? row.localId,
          'total_amount': Money.fromCents(row.totalAmount),
          'created_at': row.createdAt.toIso8601String(),
          'closed_at': row.createdAt.toIso8601String(),
        });
      }
    }
    return out;
  }

  Stream<List<LocalInvoice>> watchInvoices({int? workspaceId}) {
    final query = _db.select(_db.localInvoices)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (workspaceId != null && workspaceId > 0) {
      query.where((t) => t.workspaceId.equals(workspaceId));
    }
    return query.watch();
  }

  Future<Map<String, dynamic>?> getInvoice({
    int? workspaceId,
    required String localId,
  }) async {
    if (workspaceId != null && workspaceId > 0) {
      final row = await (_db.select(_db.localInvoices)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) & t.localId.equals(localId)))
          .getSingleOrNull();
      if (row != null) return _invoiceToMap(row);
    }
    final any = await (_db.select(_db.localInvoices)
          ..where((t) => t.localId.equals(localId)))
        .getSingleOrNull();
    if (any == null) return null;
    return _invoiceToMap(any);
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
    final invoices = await listInvoices(
      workspaceId: workspaceId,
      onDate: date,
    );
    if (invoices.isEmpty) {
      final allDay = await listInvoices(onDate: date);
      if (allDay.isNotEmpty) {
        return _reportFromInvoices(
          workspaceId: workspaceId,
          date: date,
          invoices: allDay,
        );
      }
    }
    return _reportFromInvoices(
      workspaceId: workspaceId,
      date: date,
      invoices: invoices,
    );
  }

  Future<Map<String, dynamic>> _reportFromInvoices({
    required int workspaceId,
    required DateTime date,
    required List<Map<String, dynamic>> invoices,
  }) async {
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
        'item_name': catalogItemName(raw),
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
      'subtotal': Money.fromCents(
        row.subtotal > 0
            ? row.subtotal
            : Money.toCents(payload['subtotal']),
      ),
      'discount_amount': Money.fromCents(
        row.discountAmount > 0
            ? row.discountAmount
            : Money.toCents(payload['discount_amount']),
      ),
      'tax_amount': Money.fromCents(
        row.taxAmount > 0
            ? row.taxAmount
            : Money.toCents(payload['tax_amount']),
      ),
      'total_amount': Money.fromCents(
        row.totalAmount > 0
            ? row.totalAmount
            : Money.toCents(payload['total_amount'] ?? payload['total']),
      ),
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
    if (la.year == lb.year && la.month == lb.month && la.day == lb.day) {
      return true;
    }
    final ua = a.toUtc();
    final ub = b.toUtc();
    return ua.year == ub.year && ua.month == ub.month && ua.day == ub.day;
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
