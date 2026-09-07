import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/features/cart/cart_controller.dart';

void main() {
  test('cart totals compute subtotal discount tax and total', () {
    final cart = CartController();
    cart.setTaxRate(10);
    cart.addItem(
      productLocalId: '1',
      menuItemId: 1,
      name: 'شاي',
      unitPrice: 10,
    );
    cart.addItem(
      productLocalId: '1',
      menuItemId: 1,
      name: 'شاي',
      unitPrice: 10,
    );
    cart.setDiscount(5);

    final state = cart.state;
    expect(state.lines.first.quantity, 2);
    expect(state.subtotal, 20);
    expect(state.discountAmount, 5);
    expect(state.taxAmount, 1.5);
    expect(state.total, 16.5);
    expect(state.channel, OrderChannel.table);

    final payload = cart.toOrderPayload(clientReference: 'ref-1');
    expect(payload['order_type'], 'table');
    expect(payload['client_reference'], 'ref-1');
    expect(payload['items'], isA<List>());
  });

  test('takeaway channel clears table binding', () {
    final cart = CartController();
    cart.setChannel(OrderChannel.table);
    cart.setTable(5);
    cart.setChannel(OrderChannel.takeaway);
    expect(cart.state.tableId, isNull);
    expect(cart.state.channel, OrderChannel.takeaway);
  });

  test('delivery is not collapsed into takeaway', () {
    final cart = CartController();
    cart.setChannel(OrderChannel.delivery);
    expect(cart.state.channel, OrderChannel.delivery);
    expect(cart.toOrderPayload(clientReference: 'x')['order_type'], 'delivery');
  });

  test('cashier new-order choices put takeaway beside delivery', () {
    expect(
      OrderChannelCashier.cashierChoices,
      [
        OrderChannel.table,
        OrderChannel.takeaway,
        OrderChannel.delivery,
      ],
    );
    expect(OrderChannel.takeaway.labelAr, 'طلب خارجي');
  });
}
