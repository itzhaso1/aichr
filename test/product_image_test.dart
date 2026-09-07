import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/local_db/app_database.dart';
import 'package:hasim_cashier/core/pos/application/catalog_admin_service.dart';
import 'package:hasim_cashier/core/pos/application/local_auth_service.dart';
import 'package:hasim_cashier/core/pos/application/product_image_store.dart';
import 'package:hasim_cashier/core/repositories/catalog_repository.dart';
import 'package:hasim_cashier/core/widgets/hasim_widgets.dart';

/// 1x1 PNG — real file bytes, not a random/network placeholder.
const _pngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
  });

  test('product image is copied locally and survives a new catalog read', () async {
    final dir = await Directory.systemTemp.createTemp('hasim-product-img');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/source.png');
    await source.writeAsBytes(_pngBytes);

    final admin = CatalogAdminService(db);
    final id = await admin.createProduct(
      workspaceId: 1,
      name: 'برجر بصورة',
      price: 12,
      permissions: LocalAuthService.adminPermissions,
    );
    final stored = await ProductImageStore(documentsDirectory: dir).persist(
      sourcePath: source.path,
      workspaceId: 1,
      productLocalId: id,
    );
    await admin.updateProduct(
      workspaceId: 1,
      localId: id,
      imagePath: stored,
      permissions: LocalAuthService.adminPermissions,
    );

    final first = await CatalogRepository(db).products(1);
    expect(first.single['image_path'], stored);
    expect(File('${first.single['image_path']}').existsSync(), isTrue);

    final afterRestart = await CatalogRepository(db).products(1);
    expect(afterRestart.single['image_path'], stored);
    expect(ProductImageStore.fileIfExists(afterRestart.single['image_path'] as String?), isNotNull);
  });

  test('products without an image still load', () async {
    final admin = CatalogAdminService(db);
    await admin.createProduct(
      workspaceId: 1,
      name: 'شاي بلا صورة',
      price: 5,
      permissions: LocalAuthService.adminPermissions,
    );
    final rows = await CatalogRepository(db).products(1);
    expect(rows.single['name'], 'شاي بلا صورة');
    expect(rows.single['image_path'], isNull);
    expect(ProductImageStore.fileIfExists(rows.single['image_path'] as String?), isNull);
  });

  testWidgets('product card uses a placeholder when no image file exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 220,
            child: ProductCard(
              name: 'شاي',
              priceLabel: '5.00',
              currency: 'SAR',
              onAdd: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.restaurant_menu), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
