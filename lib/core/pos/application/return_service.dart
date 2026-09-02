import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../../local_db/workspace_scope.dart';
import '../pos_errors.dart';
import '../pos_permissions.dart';
import 'stock_engine.dart';

class ReturnLineInput {
  const ReturnLineInput({
    required this.orderItemLocalId,
    required this.quantity,
  });

  final String orderItemLocalId;
  final int quantity;
}

class ReturnService {
  ReturnService(this._db, this._stock, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final StockEngine _stock;
  final String Function() _newId;

  Future<String> execute({
    required int workspaceId,
    required String orderLocalId,
    required List<ReturnLineInput> lines,
    required bool allowNegativeStock,
    String? reason,
    String? createdByUserId,
    String? shiftLocalId,
    String? deviceId,
    Map<String, dynamic>? permissions,
  }) {
    if (lines.isEmpty) throw const InvalidReturnQuantity();
    PosPermissions.require(permissions, PosPermissions.refund);
    return _db.transaction(() async {
      await _db.writeMeta(
        workspaceId,
        'return_lock',
        DateTime.now().toIso8601String(),
        deviceId: deviceId,
      );
      final order =
          await (_db.select(_db.localOrders)..where(
                (t) =>
                    t.localId.equals(orderLocalId) &
                    t.workspaceId.equals(workspaceId),
              ))
              .getSingleOrNull();
      if (order == null) {
        throw const DatabaseFailure('الطلب غير موجود.');
      }
      // Touch the order row for a write lock without changing financials.
      await (_db.update(_db.localOrders)
            ..where((t) => t.localId.equals(orderLocalId)))
          .write(LocalOrdersCompanion(updatedAt: Value(DateTime.now())));

      final invoice =
          await (_db.select(_db.localInvoices)..where(
                (t) =>
                    t.workspaceId.equals(workspaceId) &
                    t.orderLocalId.equals(orderLocalId),
              ))
              .getSingleOrNull();
      final items =
          await (_db.select(_db.localOrderItems)..where(
                (t) =>
                    t.orderLocalId.equals(orderLocalId) &
                    t.isRemoved.equals(false),
              ))
              .get();
      final byId = {for (final i in items) i.localId: i};

      final previousReturns = await (_db.select(
        _db.localReturns,
      )..where((t) => t.orderLocalId.equals(orderLocalId))).get();
      final returnIds = [for (final r in previousReturns) r.localId];
      final previous = returnIds.isEmpty
          ? const <LocalReturnItem>[]
          : await (_db.select(
              _db.localReturnItems,
            )..where((t) => t.returnLocalId.isIn(returnIds))).get();
      final already = <String, int>{};
      for (final p in previous) {
        final oid = p.orderItemLocalId;
        if (oid == null) continue;
        already[oid] = (already[oid] ?? 0) + p.quantity;
      }

      var refundCents = 0;
      final now = DateTime.now();
      final returnId = _newId();
      await _db
          .into(_db.localReturns)
          .insert(
            LocalReturnsCompanion.insert(
              localId: returnId,
              workspaceId: workspaceId,
              invoiceLocalId: Value(invoice?.localId),
              orderLocalId: Value(orderLocalId),
              reason: Value(reason),
              refundAmount: const Value(0),
              createdByUserId: Value(createdByUserId),
              shiftLocalId: Value(shiftLocalId),
              createdAt: now,
            ),
          );

      for (final line in lines) {
        final item = byId[line.orderItemLocalId];
        if (item == null) throw const InvalidReturnQuantity();
        final used = already[item.localId] ?? 0;
        if (line.quantity <= 0 || line.quantity > item.quantity - used) {
          throw const InvalidReturnQuantity();
        }
        final unitCents = item.quantity == 0
            ? 0
            : item.totalAmount ~/ item.quantity;
        final amountCents = unitCents * line.quantity;
        refundCents += amountCents;
        await _db
            .into(_db.localReturnItems)
            .insert(
              LocalReturnItemsCompanion.insert(
                localId: _newId(),
                returnLocalId: returnId,
                workspaceId: workspaceId,
                orderItemLocalId: Value(item.localId),
                productLocalId: Value(item.productLocalId),
                productNameSnapshot: item.name,
                quantity: line.quantity,
                refundAmount: amountCents,
              ),
            );
        if (item.productLocalId != null) {
          await _stock.apply(
            workspaceId: workspaceId,
            productLocalId: item.productLocalId!,
            type: 'return',
            quantity: line.quantity,
            allowNegative: allowNegativeStock,
            referenceType: 'return',
            referenceId: returnId,
            userId: createdByUserId,
            deviceId: deviceId,
          );
        }
      }

      await (_db.update(_db.localReturns)
            ..where((t) => t.localId.equals(returnId)))
          .write(
            LocalReturnsCompanion(
              refundAmount: Value(refundCents),
            ),
          );

      if (shiftLocalId != null && refundCents > 0) {
        final shift =
            await (_db.select(_db.localShifts)..where(
                  (t) =>
                      t.localId.equals(shiftLocalId) &
                      t.status.equals('open'),
                ))
                .getSingleOrNull();
        if (shift == null) throw const ShiftNotOpen();
        await _db
            .into(_db.localCashMovements)
            .insert(
              LocalCashMovementsCompanion.insert(
                localId: _newId(),
                workspaceId: workspaceId,
                shiftLocalId: shiftLocalId,
                type: 'refund',
                amount: refundCents,
                reason: Value(reason ?? 'مرتجع'),
                referenceId: Value(returnId),
                createdByUserId: Value(createdByUserId),
                createdAt: now,
              ),
            );
      }
      // Original invoice totals stay immutable.
      return returnId;
    });
  }
}
