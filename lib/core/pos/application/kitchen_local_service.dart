import 'package:drift/drift.dart';

import '../../local_db/app_database.dart';

/// Kitchen board reads/writes SQLite. Network is optional enrichment only.
class KitchenLocalService {
  KitchenLocalService(this._db);

  final AppDatabase _db;

  static const activeStatuses = ['new', 'accepted', 'preparing', 'ready'];

  Stream<List<Map<String, dynamic>>> watchActive(int workspaceId) {
    final query = _db.select(_db.localOrders)
      ..where(
        (t) =>
            t.workspaceId.equals(workspaceId) &
            t.posStatus.isIn(activeStatuses) &
            t.posStatus.isNotValue('cancelled'),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    return query.watch().asyncMap((rows) async {
      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        final items =
            await (_db.select(_db.localOrderItems)..where(
                  (t) =>
                      t.orderLocalId.equals(row.localId) &
                      t.isRemoved.equals(false),
                ))
                .get();
        out.add({
          'id': row.serverId ?? row.localId,
          'local_id': row.localId,
          'order_number': row.orderNumber ?? row.localId,
          'order_type': row.orderType,
          'pos_status': row.posStatus,
          'payment_status': row.paymentStatus,
          'notes': row.notes,
          'created_at': row.createdAt.toIso8601String(),
          'items': [
            for (final item in items)
              {
                'id': item.localId,
                'item_name': item.name,
                'quantity': item.quantity,
                'notes': item.notes,
              },
          ],
        });
      }
      return out;
    });
  }

  Future<void> updateStatus({
    required int workspaceId,
    required String orderLocalId,
    required String status,
  }) async {
    await (_db.update(_db.localOrders)..where(
          (t) =>
              t.localId.equals(orderLocalId) &
              t.workspaceId.equals(workspaceId),
        ))
        .write(
          LocalOrdersCompanion(
            posStatus: Value(status),
            fulfillmentStatus: Value(
              status == 'completed' || status == 'delivered'
                  ? 'fulfilled'
                  : 'unfulfilled',
            ),
            updatedAt: Value(DateTime.now()),
            completedAt: status == 'completed' || status == 'delivered'
                ? Value(DateTime.now())
                : const Value.absent(),
          ),
        );
  }
}
