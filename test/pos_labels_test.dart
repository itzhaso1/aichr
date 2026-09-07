import 'package:flutter/material.dart';
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

  test('kitchen status colors match the requested legend', () {
    expect(PosLabels.statusColor('new'), const Color(0xFF2563EB));
    expect(PosLabels.statusColor('accepted'), const Color(0xFF059669));
    expect(PosLabels.statusColor('preparing'), const Color(0xFFD97706));
    expect(PosLabels.statusColor('cancelled'), const Color(0xFFDC2626));
    expect(PosLabels.statusSoft('new'), const Color(0xFFDBEAFE));
    expect(PosLabels.statusSoft('accepted'), const Color(0xFFD1FAE5));
    expect(PosLabels.statusSoft('preparing'), const Color(0xFFFEF3C7));
    expect(PosLabels.statusSoft('cancelled'), const Color(0xFFFFE4E6));
  });
}
