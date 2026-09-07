import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/pos/pos_labels.dart';

void main() {
  test('pos status labels match Laravel Arabic copy', () {
    expect(PosLabels.status('new'), 'جديد');
    expect(PosLabels.status('accepted'), 'مقبول');
    expect(PosLabels.status('preparing'), 'قيد التحضير');
    expect(PosLabels.status('ready'), 'جاهز');
    expect(PosLabels.status('completed'), 'مكتمل');
    expect(PosLabels.status('cancelled'), 'ملغي');
  });

  test('order type never uses session wording for takeaway', () {
    expect(PosLabels.orderType('takeaway'), 'طلب خارجي');
    expect(PosLabels.orderType('table'), 'طاولة');
    expect(PosLabels.orderType('delivery'), 'توصيل');
    expect(PosLabels.kitchenHeading(orderType: 'takeaway'), 'طلب خارجي');
    expect(PosLabels.kitchenHeading(orderType: 'delivery'), 'توصيل');
    expect(
      PosLabels.kitchenHeading(orderType: 'table', tableName: 'طاولة 4'),
      'طاولة 4',
    );
  });

  test('table status labels match web board', () {
    expect(PosLabels.tableStatus('occupied'), 'مشغولة');
    expect(PosLabels.tableStatus('available'), 'فارغة');
    expect(PosLabels.tableStatus(null), 'فارغة');
  });
}
