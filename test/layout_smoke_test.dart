import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/widgets/hasim_widgets.dart';
import 'package:hasim_cashier/core/widgets/pos_tap.dart';
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

  bool hasHitTestStorm() => errors.any(
        (e) =>
            '$e'.contains('no size') ||
            '$e'.contains('_debugDuringDeviceUpdate') ||
            '$e'.contains('PointerAddedEvent') ||
            '$e'.contains('Null check operator'),
      );

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
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
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
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
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
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
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
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
  });

  testWidgets('nav pills and product hover path do not throw mouse_tracker',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Row(
                children: [
                  HsNavPill(label: 'الكاشير', selected: true, onTap: () {}),
                  HsNavPill(label: 'التقارير', selected: false, onTap: () {}),
                ],
              ),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: 4,
                  itemBuilder: (_, i) => ProductCard(
                    name: 'صنف $i',
                    priceLabel: '5.00',
                    currency: 'SAR',
                    onAdd: () => taps++,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    final card = tester.getCenter(find.byType(ProductCard).first);
    await gesture.moveTo(card);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('التقارير')));
    await tester.pump();
    await tester.tap(find.byType(ProductCard).first);
    await tester.pump();

    expect(taps, 1);
    expect(find.byType(PosTap), findsWidgets);
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
  });

  testWidgets('rapid taps under mouse hover do not trip no-size asserts',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.7,
            ),
            itemCount: 12,
            itemBuilder: (_, i) => ProductCard(
              name: 'P$i',
              priceLabel: '1.00',
              currency: 'SAR',
              onAdd: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(ProductCard).at(1)),
    );
    await tester.pump();

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byType(ProductCard).at(i % 3));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byType(ProductCard).at((i + 1) % 3)),
      );
      await tester.pump();
    }

    expect(taps, 5);
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
  });

  testWidgets('rebuild under hovering mouse does not trip mouse_tracker',
      (tester) async {
    var version = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => version++),
                    child: Text('rebuild-$version'),
                  ),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: 0.75,
                      ),
                      itemCount: 6,
                      itemBuilder: (_, i) => ProductCard(
                        key: ValueKey('v$version-$i'),
                        name: 'صنف $i v$version',
                        priceLabel: '5.00',
                        currency: 'SAR',
                        onAdd: () => setState(() => version++),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(ProductCard).first));
    await tester.pump();

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.textContaining('rebuild-'));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ProductCard).first));
      await tester.pump();
    }

    await tester.tap(find.byType(ProductCard).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
  });
}

void _noop() {}
