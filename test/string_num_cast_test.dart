import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/offline/pending_order.dart';
import 'package:hasim_cashier/core/pos/domain/pricing_service.dart';
import 'package:hasim_cashier/core/util/json_numbers.dart';

void main() {
  test('PendingOrder.fromRecord accepts string ids and money', () {
    final order = PendingOrder.fromRecord({
      'local_id': 'abc',
      'idempotency_key': 'abc',
      'workspace_id': '1',
      'table_id': '7',
      'order_type': 'table',
      'retry_count': '2',
      'server_order_id': '99',
      'items': [
        {
          'name': 'شاي',
          'quantity': '2',
          'unit_price': '5.50',
          'total_amount': '11.00',
        },
      ],
    });
    expect(order.workspaceId, 1);
    expect(order.tableId, 7);
    expect(order.retryCount, 2);
    expect(order.serverOrderId, 99);
    expect(order.subtotal, 11);
    expect(() => order.toDisplayOrder(), returnsNormally);
    expect(order.toDisplayOrder()['total_amount'], 11);
  });

  test('catalog-like string payloads never need as num', () {
    final item = {
      'id': 'uuid-local',
      'price': '12.50',
      'pos_item_category_id': '3',
      'quantity': '2',
      'unit_price': '10',
    };
    expect(asInt(item['id']), isNull);
    expect(asDoubleOr(item['price']), 12.5);
    expect(asInt(item['pos_item_category_id']), 3);
    expect(asIntOr(item['quantity'], 1), 2);
    expect(Money.toCents(item['unit_price']), 1000);
  });
}
