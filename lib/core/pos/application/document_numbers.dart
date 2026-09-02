import 'package:drift/drift.dart';

import '../../local_db/app_database.dart';

/// Transaction-safe document sequences. Never uses max(id)+1.
///
/// Increment is a single INSERT … ON CONFLICT UPDATE so concurrent checkouts
/// inside SQLite serialized writes cannot issue the same number.
class DocumentNumberService {
  DocumentNumberService(this._db);

  final AppDatabase _db;

  Future<String> nextInvoiceNumber({
    required String storeId,
    String prefix = 'INV-',
  }) {
    return _next(storeId: storeId, kind: 'invoice', prefix: prefix, width: 6);
  }

  Future<String> nextOrderNumber({
    required String storeId,
    String prefix = 'ORD-',
  }) {
    return _next(storeId: storeId, kind: 'order', prefix: prefix, width: 6);
  }

  Future<String> _next({
    required String storeId,
    required String kind,
    required String prefix,
    required int width,
  }) async {
    final now = DateTime.now();
    await _db.customInsert(
      'INSERT INTO local_sequences (store_id, kind, next_value, updated_at) '
      'VALUES (?, ?, 2, ?) '
      'ON CONFLICT(store_id, kind) DO UPDATE SET '
      'next_value = next_value + 1, updated_at = excluded.updated_at',
      variables: [
        Variable.withString(storeId),
        Variable.withString(kind),
        Variable.withDateTime(now),
      ],
    );
    final row =
        await (_db.select(_db.localSequences)
              ..where((t) => t.storeId.equals(storeId) & t.kind.equals(kind)))
            .getSingle();
    final issued = row.nextValue - 1;
    return '$prefix${issued.toString().padLeft(width, '0')}';
  }
}
