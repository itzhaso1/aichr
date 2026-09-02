import 'package:drift/drift.dart';

import '../../local_db/app_database.dart';
import '../../util/json_numbers.dart';
import '../domain/pricing_service.dart';

class LocalReportsService {
  LocalReportsService(this._db);

  final AppDatabase _db;

  static const recentInvoiceLimit = 100;

  (DateTime, DateTime) _dayRange(DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    return (start, start.add(const Duration(days: 1)));
  }

  int _asInt(Object? value) => asIntOr(value);

  Future<Map<String, dynamic>> daily({
    required int workspaceId,
    required DateTime date,
  }) async {
    final (from, to) = _dayRange(date);
    final vars = [
      Variable.withInt(workspaceId),
      Variable.withDateTime(from),
      Variable.withDateTime(to),
    ];

    final invAgg = (await _db.customSelect(
      'SELECT COUNT(*) AS c, '
      'COALESCE(SUM(subtotal), 0) AS subtotal, '
      'COALESCE(SUM(discount_amount), 0) AS discount, '
      'COALESCE(SUM(tax_amount), 0) AS tax, '
      'COALESCE(SUM(total_amount), 0) AS total '
      'FROM local_invoices '
      'WHERE workspace_id = ? AND created_at >= ? AND created_at < ?',
      variables: vars,
    ).get())
        .single
        .data;

    final invoicesCount = _asInt(invAgg['c']);
    var subtotalCents = _asInt(invAgg['subtotal']);
    var discountCents = _asInt(invAgg['discount']);
    var taxCents = _asInt(invAgg['tax']);
    var grossCents = _asInt(invAgg['total']);

    final orderAgg = (await _db.customSelect(
      'SELECT COUNT(*) AS c '
      'FROM local_orders '
      'WHERE workspace_id = ? AND pos_status != ? '
      'AND created_at >= ? AND created_at < ?',
      variables: [
        Variable.withInt(workspaceId),
        Variable.withString('cancelled'),
        Variable.withDateTime(from),
        Variable.withDateTime(to),
      ],
    ).get())
        .single
        .data;
    final ordersCount = _asInt(orderAgg['c']);

    if (grossCents <= 0) {
      final paid = (await _db.customSelect(
        'SELECT COALESCE(SUM(subtotal), 0) AS subtotal, '
        'COALESCE(SUM(discount_amount), 0) AS discount, '
        'COALESCE(SUM(tax_amount), 0) AS tax, '
        'COALESCE(SUM(total_amount), 0) AS total '
        'FROM local_orders '
        'WHERE workspace_id = ? AND pos_status != ? AND payment_status = ? '
        'AND created_at >= ? AND created_at < ?',
        variables: [
          Variable.withInt(workspaceId),
          Variable.withString('cancelled'),
          Variable.withString('paid'),
          Variable.withDateTime(from),
          Variable.withDateTime(to),
        ],
      ).get())
          .single
          .data;
      subtotalCents = _asInt(paid['subtotal']);
      discountCents = _asInt(paid['discount']);
      taxCents = _asInt(paid['tax']);
      grossCents = _asInt(paid['total']);
    }

    final payRows = await _db.customSelect(
      'SELECT method, COUNT(*) AS c, COALESCE(SUM(amount), 0) AS total '
      'FROM local_payments '
      'WHERE workspace_id = ? AND created_at >= ? AND created_at < ? '
      'GROUP BY method',
      variables: vars,
    ).get();

    final retAgg = (await _db.customSelect(
      'SELECT COUNT(*) AS c, COALESCE(SUM(refund_amount), 0) AS amt '
      'FROM local_returns '
      'WHERE workspace_id = ? AND created_at >= ? AND created_at < ?',
      variables: vars,
    ).get())
        .single
        .data;
    final returnCount = _asInt(retAgg['c']);
    final returnCents = _asInt(retAgg['amt']);

    final cogsRow = (await _db.customSelect(
      'SELECT COALESCE(SUM(i.cost_snapshot * i.quantity), 0) AS cogs '
      'FROM local_order_items i '
      'INNER JOIN local_orders o ON o.local_id = i.order_local_id '
      'WHERE i.workspace_id = ? AND i.is_removed = 0 '
      'AND o.workspace_id = ? AND o.pos_status != ? AND o.payment_status = ? '
      'AND o.created_at >= ? AND o.created_at < ?',
      variables: [
        Variable.withInt(workspaceId),
        Variable.withInt(workspaceId),
        Variable.withString('cancelled'),
        Variable.withString('paid'),
        Variable.withDateTime(from),
        Variable.withDateTime(to),
      ],
    ).get())
        .single
        .data;
    final cogsCents = _asInt(cogsRow['cogs']);

    final topRows = await _db.customSelect(
      'SELECT i.name AS name, SUM(i.quantity) AS qty, '
      'SUM(i.total_amount) AS rev '
      'FROM local_order_items i '
      'INNER JOIN local_orders o ON o.local_id = i.order_local_id '
      'WHERE i.workspace_id = ? AND i.is_removed = 0 '
      'AND o.workspace_id = ? AND o.pos_status != ? AND o.payment_status = ? '
      'AND o.created_at >= ? AND o.created_at < ? '
      'GROUP BY i.name '
      'ORDER BY qty DESC '
      'LIMIT 20',
      variables: [
        Variable.withInt(workspaceId),
        Variable.withInt(workspaceId),
        Variable.withString('cancelled'),
        Variable.withString('paid'),
        Variable.withDateTime(from),
        Variable.withDateTime(to),
      ],
    ).get();

    final invoiceRows = await _db.customSelect(
      'SELECT local_id, local_invoice_number, invoice_number, '
      'total_amount, tax_amount, discount_amount, created_at '
      'FROM local_invoices '
      'WHERE workspace_id = ? AND created_at >= ? AND created_at < ? '
      'ORDER BY created_at DESC '
      'LIMIT $recentInvoiceLimit',
      variables: vars,
    ).get();

    final netCents = grossCents - returnCents;

    return {
      'date':
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      'source': 'local_sqlite',
      'summary': {
        'invoice_sales_total': Money.fromCents(grossCents),
        'invoices_total': Money.fromCents(grossCents),
        'invoices_count': invoicesCount,
        'orders_count': ordersCount,
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
      'payment_methods': [
        for (final row in payRows)
          {
            'method': row.data['method'],
            'total': Money.fromCents(_asInt(row.data['total'])),
            'count': _asInt(row.data['c']),
          },
      ],
      'top_items': [
        for (final row in topRows)
          {
            'product_name': row.data['name'],
            'quantity': _asInt(row.data['qty']),
            'sales': Money.fromCents(_asInt(row.data['rev'])),
          },
      ],
      'invoices': [
        for (final row in invoiceRows)
          {
            'id': row.data['local_id'],
            'local_id': row.data['local_id'],
            'invoice_number':
                row.data['local_invoice_number'] ?? row.data['invoice_number'],
            'total_amount': Money.fromCents(_asInt(row.data['total_amount'])),
            'tax_amount': Money.fromCents(_asInt(row.data['tax_amount'])),
            'discount_amount':
                Money.fromCents(_asInt(row.data['discount_amount'])),
            'created_at': _invoiceCreatedAt(row.data['created_at']),
          },
      ],
    };
  }

  String _invoiceCreatedAt(Object? raw) {
    if (raw is DateTime) return raw.toIso8601String();
    if (raw is int) {
      final seconds = raw > 100000000000 ? raw ~/ 1000 : raw;
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toIso8601String();
    }
    return raw?.toString() ?? '';
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
