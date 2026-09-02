import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../domain/pricing_service.dart';

/// Persistent cart / draft order. Survives app kill.
class DraftCartStore {
  DraftCartStore(this._db, {this.pricing = const PricingService()});

  final AppDatabase _db;
  final PricingService pricing;
  final _uuid = const Uuid();

  Future<String> _activeCartId({
    required int workspaceId,
    required String channel,
    String? tableLocalId,
  }) async {
    final query = _db.select(_db.localDraftCarts)
      ..where(
        (t) => t.workspaceId.equals(workspaceId) & t.channel.equals(channel),
      );
    if (tableLocalId != null) {
      query.where((t) => t.tableLocalId.equals(tableLocalId));
    } else {
      query.where((t) => t.tableLocalId.isNull());
    }
    final existing = await query.getSingleOrNull();
    if (existing != null) return existing.localId;
    final id = _uuid.v4();
    await _db
        .into(_db.localDraftCarts)
        .insert(
          LocalDraftCartsCompanion.insert(
            localId: id,
            workspaceId: workspaceId,
            channel: channel,
            tableLocalId: Value(tableLocalId),
            updatedAt: DateTime.now(),
          ),
        );
    return id;
  }

  Future<void> save({
    required int workspaceId,
    required String channel,
    required List<PricedLine> lines,
    String? tableLocalId,
    int? tableServerId,
    String? customerLocalId,
    String? notes,
    double discountAmount = 0,
    double discountPercent = 0,
    double taxRate = 0,
  }) {
    return _db.transaction(() async {
      final cartId = await _activeCartId(
        workspaceId: workspaceId,
        channel: channel,
        tableLocalId: tableLocalId,
      );
      final now = DateTime.now();
      await (_db.update(
        _db.localDraftCarts,
      )..where((t) => t.localId.equals(cartId))).write(
        LocalDraftCartsCompanion(
          tableServerId: Value(tableServerId),
          customerLocalId: Value(customerLocalId),
          notes: Value(notes),
          discountAmount: Value(Money.toCents(discountAmount)),
          discountPercent: Value(discountPercent),
          taxRate: Value(taxRate),
          updatedAt: Value(now),
        ),
      );
      await (_db.delete(
        _db.localDraftCartLines,
      )..where((t) => t.cartLocalId.equals(cartId))).go();
      for (final line in lines) {
        await _db
            .into(_db.localDraftCartLines)
            .insert(
              LocalDraftCartLinesCompanion.insert(
                localId: _uuid.v4(),
                cartLocalId: cartId,
                workspaceId: workspaceId,
                productLocalId: line.productLocalId,
                productServerId: Value(line.productServerId),
                name: line.name,
                sku: Value(line.sku),
                barcode: Value(line.barcode),
                quantity: line.quantity,
                unitPrice: line.unitPriceCents,
                cost: Value(Money.toCents(line.cost)),
                discountAmount: Value(Money.toCents(line.itemDiscount)),
                taxRate: Value(line.taxRate),
                updatedAt: now,
              ),
            );
      }
    });
  }

  Future<
    ({
      String channel,
      String? tableLocalId,
      int? tableServerId,
      String? customerLocalId,
      String? notes,
      double discountAmount,
      double discountPercent,
      double taxRate,
      List<PricedLine> lines,
    })?
  >
  load({
    required int workspaceId,
    required String channel,
    String? tableLocalId,
  }) async {
    final query = _db.select(_db.localDraftCarts)
      ..where(
        (t) => t.workspaceId.equals(workspaceId) & t.channel.equals(channel),
      );
    if (tableLocalId != null) {
      query.where((t) => t.tableLocalId.equals(tableLocalId));
    } else {
      query.where((t) => t.tableLocalId.isNull());
    }
    final cart = await query.getSingleOrNull();
    if (cart == null) return null;
    final lines = await (_db.select(
      _db.localDraftCartLines,
    )..where((t) => t.cartLocalId.equals(cart.localId))).get();
    return (
      channel: cart.channel,
      tableLocalId: cart.tableLocalId,
      tableServerId: cart.tableServerId,
      customerLocalId: cart.customerLocalId,
      notes: cart.notes,
      discountAmount: Money.fromCents(cart.discountAmount),
      discountPercent: cart.discountPercent,
      taxRate: cart.taxRate,
      lines: [
        for (final line in lines)
          PricedLine(
            productLocalId: line.productLocalId,
            productServerId: line.productServerId,
            name: line.name,
            quantity: line.quantity,
            unitPrice: Money.fromCents(line.unitPrice),
            itemDiscount: Money.fromCents(line.discountAmount),
            taxRate: line.taxRate,
            sku: line.sku,
            barcode: line.barcode,
            cost: Money.fromCents(line.cost),
          ),
      ],
    );
  }

  Future<void> clear({
    required int workspaceId,
    required String channel,
    String? tableLocalId,
  }) async {
    final query = _db.select(_db.localDraftCarts)
      ..where(
        (t) => t.workspaceId.equals(workspaceId) & t.channel.equals(channel),
      );
    if (tableLocalId != null) {
      query.where((t) => t.tableLocalId.equals(tableLocalId));
    } else {
      query.where((t) => t.tableLocalId.isNull());
    }
    final cart = await query.getSingleOrNull();
    if (cart == null) return;
    await (_db.delete(
      _db.localDraftCartLines,
    )..where((t) => t.cartLocalId.equals(cart.localId))).go();
    await (_db.delete(
      _db.localDraftCarts,
    )..where((t) => t.localId.equals(cart.localId))).go();
  }
}
