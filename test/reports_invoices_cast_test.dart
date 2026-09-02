import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/pos/domain/pricing_service.dart';
import 'package:hasim_cashier/core/util/json_numbers.dart';

void main() {
  test('Money.toCents accepts numeric strings without throwing', () {
    expect(Money.toCents('12.50'), 1250);
    expect(Money.toCents('10'), 1000);
    expect(Money.toCents(10.5), 1050);
    expect(Money.toCents(null), 0);
    expect(Money.toCents('bad'), 0);
    // Exact crash that used to red-screen reports/invoices:
    expect(() => Money.toCents('23.00'), returnsNormally);
  });

  test('report/invoice string money display path never casts as num', () {
    final inv = {
      'total_amount': '23.00',
      'tax_amount': '3',
      'subtotal': '20',
      'discount_amount': '0',
      'table': 'طاولة 1',
      'items': [
        {
          'item_name': 'شاي',
          'quantity': '2',
          'unit_price': '10',
          'total_amount': '20',
        },
      ],
    };
    expect(asDoubleOr(inv['total_amount']).toStringAsFixed(2), '23.00');
    expect(asDoubleOr(inv['tax_amount']).toStringAsFixed(2), '3.00');
    expect(nestedName(inv['table']), 'طاولة 1');
    for (final item in asMapList(inv['items'])) {
      expect(asIntOr(item['quantity'], 1), 2);
      expect(asDoubleOr(item['total_amount']).toStringAsFixed(2), '20.00');
    }
    final summary = {
      'invoice_sales_total': '100.5',
      'invoices_count': '4',
    };
    expect(asDoubleOr(summary['invoice_sales_total']).toStringAsFixed(2), '100.50');
    expect(asIntOr(summary['invoices_count']), 4);
  });
}
