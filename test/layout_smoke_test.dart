import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/widgets/hasim_widgets.dart';
import 'package:hasim_cashier/features/tables/table_action_wizards.dart';

void main() {
  final errors = <Object>[];

  setUp(() {
    errors.clear();
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exception);
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
  });

  testWidgets('product grid cards do not throw layout/semantics errors',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.68,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemCount: 9,
            itemBuilder: (_, i) => ProductCard(
              name: 'منتج تجريبي رقم $i',
              priceLabel: '15.00',
              currency: 'SAR',
              sku: 'SKU-$i',
              onAdd: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ProductCard).first);
    await tester.pump();
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  testWidgets('product card with zero constraints does not throw hit-test errors',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 0,
            height: 0,
            child: ProductCard(
              name: 'x',
              priceLabel: '1',
              currency: 'SAR',
              onAdd: _noop,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tapAt(Offset.zero);
    await tester.pump();
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  testWidgets('compact cashier grid hit-tests without zero-size errors',
      (tester) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 56),
              Expanded(
                child: GridView.builder(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.68,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: 6,
                  itemBuilder: (_, i) => ProductCard(
                    name: 'منتج $i',
                    priceLabel: '10.00',
                    currency: 'SAR',
                    sku: 'S$i',
                    onAdd: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ProductCard).first);
    await tester.pump();
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  testWidgets('transfer wizard dialog pumps without parentDataDirty',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => const TableTransferWizard(
                    title: 'نقل الطاولة',
                    currentTableName: 'T1',
                    candidates: [
                      {'id': 2, 'name': 'T2', 'status': 'available'},
                    ],
                    confirmLabel: 'تأكيد',
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('نقل الطاولة'), findsOneWidget);
    expect(errors, isEmpty, reason: errors.join('\n'));
  });
}

void _noop() {}
