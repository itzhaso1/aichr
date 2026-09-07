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

  testWidgets('product grid cards do not throw layout/semantics errors', (
    tester,
  ) async {
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

  testWidgets(
    'product card with zero constraints does not throw hit-test errors',
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
    },
  );

  testWidgets('compact cashier grid hit-tests without zero-size errors', (
    tester,
  ) async {
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
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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

  testWidgets('transfer wizard dialog pumps without parentDataDirty', (
    tester,
  ) async {
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

  testWidgets(
    'transfer wizard accepts string table ids without String-as-num',
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
                        {'id': '2', 'name': 'T2', 'status': 'available'},
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
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('T2'), findsOneWidget);
      expect(errors.where((e) => '$e'.contains('subtype')), isEmpty);
    },
  );

  testWidgets(
    'split bill wizard accepts string qty/price without String-as-num',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SplitBillWizard(
            sessionTotal: 20,
            items: [
              {
                'name': 'شاي',
                'quantity': '2',
                'unit_price': '10.00',
                'order_item_id': '11',
              },
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('المتاح: 2'), findsOneWidget);
      expect(errors.where((e) => '$e'.contains('subtype')), isEmpty);
    },
  );

  testWidgets('nav pills and product hover path do not throw mouse_tracker', (
    tester,
  ) async {
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

  testWidgets('rapid taps under mouse hover do not trip no-size asserts', (
    tester,
  ) async {
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

  testWidgets('rebuild under hovering mouse does not trip mouse_tracker', (
    tester,
  ) async {
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

  testWidgets(
    'switching off a hovered product grid does not storm mouse_tracker',
    (tester) async {
      var tab = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    Row(
                      children: [
                        HsNavPill(
                          label: 'الكاشير',
                          selected: tab == 0,
                          onTap: () => setState(() => tab = 0),
                        ),
                        HsNavPill(
                          label: 'التقارير',
                          selected: tab == 1,
                          onTap: () => setState(() => tab = 1),
                        ),
                        HsNavPill(
                          label: 'الفواتير',
                          selected: tab == 2,
                          onTap: () => setState(() => tab = 2),
                        ),
                      ],
                    ),
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Offstage(
                            offstage: tab != 0,
                            child: TickerMode(
                              enabled: tab == 0,
                              child: GridView.builder(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3,
                                      childAspectRatio: 0.7,
                                    ),
                                itemCount: 9,
                                itemBuilder: (_, i) => ProductCard(
                                  name: 'صنف $i',
                                  priceLabel: '5.00',
                                  currency: 'SAR',
                                  onAdd: () {},
                                ),
                              ),
                            ),
                          ),
                          if (tab == 1) const Center(child: Text('تقرير يومي')),
                          if (tab == 2)
                            const Center(child: Text('قائمة الفواتير')),
                        ],
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
      await gesture.addPointer(
        location: tester.getCenter(find.byType(ProductCard).first),
      );
      addTearDown(gesture.removePointer);
      await tester.pump();

      await tester.tap(find.text('التقارير'));
      await tester.pump();
      expect(find.text('تقرير يومي'), findsOneWidget);

      await tester.tap(find.text('الفواتير'));
      await tester.pump();
      expect(find.text('قائمة الفواتير'), findsOneWidget);
      expect(find.text('تقرير يومي'), findsNothing);

      await tester.tap(find.text('الكاشير'));
      await tester.pump();
      expect(find.text('قائمة الفواتير'), findsNothing);
      expect(find.text('تقرير يومي'), findsNothing);
      expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
    },
  );

  testWidgets('nav pills fire immediately without PosTap gating', (
    tester,
  ) async {
    var selected = 'الكاشير';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  Row(
                    children: [
                      for (final label in const [
                        'الكاشير',
                        'التقارير',
                        'الفواتير',
                      ])
                        HsNavPill(
                          label: label,
                          selected: selected == label,
                          onTap: () => setState(() => selected = label),
                        ),
                    ],
                  ),
                  Expanded(child: Text('section:$selected')),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(HsNavPill).first,
        matching: find.byType(PosTap),
      ),
      findsNothing,
    );

    await tester.tap(find.text('التقارير'));
    await tester.pump();
    expect(find.text('section:التقارير'), findsOneWidget);

    await tester.tap(find.text('الفواتير'));
    await tester.pump();
    expect(find.text('section:الفواتير'), findsOneWidget);
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
  });

  testWidgets('HsSoftGrid lays two tiles across on a wide bounded width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              HsSoftGrid(
                minTileWidth: 300,
                maxColumns: 3,
                children: [
                  for (var i = 0; i < 4; i++) HsCard(child: Text('card-$i')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final boxes = tester
        .renderObjectList<RenderBox>(find.byType(HsCard))
        .toList();
    expect(boxes.length, 4);
    expect(boxes.first.size.width, closeTo((800 - 8) / 2, 1));
    expect(
      boxes[1].localToGlobal(Offset.zero).dy,
      closeTo(boxes.first.localToGlobal(Offset.zero).dy, 1),
    );
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
  });

  testWidgets('HsSelectField opens a compact options dialog', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HsSelectField(
            valueLabel: 'كل الفواتير',
            options: const [
              (value: 'all', label: 'كل الفواتير'),
              (value: 'inv:1', label: 'INV-1'),
            ],
            onSelected: (v) => selected = v,
          ),
        ),
      ),
    );
    await tester.tap(find.text('كل الفواتير'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.tap(find.text('INV-1'));
    await tester.pumpAndSettle();
    expect(selected, 'inv:1');
    expect(hasHitTestStorm(), isFalse, reason: errors.join('\n'));
  });
}

void _noop() {}
