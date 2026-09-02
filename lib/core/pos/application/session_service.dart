import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../domain/pricing_service.dart';
import '../pos_errors.dart';

/// Table dining sessions live in SQLite, not JSON on LocalTables.
class TableSessionService {
  TableSessionService(this._db, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final String Function() _newId;

  Future<LocalSession?> openSessionForTable({
    required int workspaceId,
    required String tableLocalId,
  }) {
    return (_db.select(_db.localSessions)
          ..where(
            (t) =>
                t.workspaceId.equals(workspaceId) &
                t.tableLocalId.equals(tableLocalId) &
                t.status.equals('open'),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<String> open({
    required int workspaceId,
    required String tableLocalId,
    String? openedByUserId,
    String? notes,
  }) {
    return _db.transaction(() async {
      final existing = await openSessionForTable(
        workspaceId: workspaceId,
        tableLocalId: tableLocalId,
      );
      if (existing != null) return existing.localId;
      final id = _newId();
      final now = DateTime.now();
      await _db
          .into(_db.localSessions)
          .insert(
            LocalSessionsCompanion.insert(
              localId: id,
              workspaceId: workspaceId,
              tableLocalId: tableLocalId,
              status: const Value('open'),
              openedAt: now,
              openedByUserId: Value(openedByUserId),
              notes: Value(notes),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await (_db.update(
        _db.localTables,
      )..where((t) => t.localId.equals(tableLocalId))).write(
        LocalTablesCompanion(
          status: const Value('occupied'),
          updatedAt: Value(now),
        ),
      );
      return id;
    });
  }

  Future<void> setNotes({
    required String sessionId,
    required String? notes,
  }) async {
    await (_db.update(
      _db.localSessions,
    )..where((t) => t.localId.equals(sessionId))).write(
      LocalSessionsCompanion(
        notes: Value(notes),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> setDiscount({
    required String sessionId,
    required double amount,
  }) async {
    if (amount < 0) throw const InvalidDiscount();
    await (_db.update(
      _db.localSessions,
    )..where((t) => t.localId.equals(sessionId))).write(
      LocalSessionsCompanion(
        discountAmount: Value(Money.toCents(amount)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> transfer({
    required int workspaceId,
    required String sessionId,
    required String toTableLocalId,
  }) {
    return _db.transaction(() async {
      final session = await (_db.select(
        _db.localSessions,
      )..where((t) => t.localId.equals(sessionId))).getSingleOrNull();
      if (session == null || session.status != 'open') {
        throw const DatabaseFailure('الجلسة غير مفتوحة.');
      }
      final now = DateTime.now();
      await (_db.update(
        _db.localTables,
      )..where((t) => t.localId.equals(session.tableLocalId))).write(
        LocalTablesCompanion(
          status: const Value('available'),
          updatedAt: Value(now),
        ),
      );
      await (_db.update(
        _db.localSessions,
      )..where((t) => t.localId.equals(sessionId))).write(
        LocalSessionsCompanion(
          tableLocalId: Value(toTableLocalId),
          updatedAt: Value(now),
        ),
      );
      await (_db.update(
        _db.localTables,
      )..where((t) => t.localId.equals(toTableLocalId))).write(
        LocalTablesCompanion(
          status: const Value('occupied'),
          updatedAt: Value(now),
        ),
      );
    });
  }

  Future<void> merge({
    required int workspaceId,
    required String fromSessionId,
    required String intoSessionId,
  }) {
    return _db.transaction(() async {
      if (fromSessionId == intoSessionId) return;
      final now = DateTime.now();
      await (_db.update(
        _db.localOrders,
      )..where((t) => t.sessionLocalId.equals(fromSessionId))).write(
        LocalOrdersCompanion(
          sessionLocalId: Value(intoSessionId),
          updatedAt: Value(now),
        ),
      );
      final from = await (_db.select(
        _db.localSessions,
      )..where((t) => t.localId.equals(fromSessionId))).getSingleOrNull();
      await (_db.update(
        _db.localSessions,
      )..where((t) => t.localId.equals(fromSessionId))).write(
        LocalSessionsCompanion(
          status: const Value('merged'),
          closedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      if (from != null) {
        await (_db.update(
          _db.localTables,
        )..where((t) => t.localId.equals(from.tableLocalId))).write(
          LocalTablesCompanion(
            status: const Value('available'),
            updatedAt: Value(now),
          ),
        );
      }
    });
  }

  Future<void> close({
    required int workspaceId,
    required String sessionId,
    String? closedByUserId,
  }) {
    return _db.transaction(() async {
      final session = await (_db.select(
        _db.localSessions,
      )..where((t) => t.localId.equals(sessionId))).getSingleOrNull();
      if (session == null) {
        throw const DatabaseFailure('الجلسة غير موجودة.');
      }
      final now = DateTime.now();
      await (_db.update(
        _db.localSessions,
      )..where((t) => t.localId.equals(sessionId))).write(
        LocalSessionsCompanion(
          status: const Value('closed'),
          closedAt: Value(now),
          closedByUserId: Value(closedByUserId),
          updatedAt: Value(now),
        ),
      );
      await (_db.update(
        _db.localTables,
      )..where((t) => t.localId.equals(session.tableLocalId))).write(
        LocalTablesCompanion(
          status: const Value('available'),
          updatedAt: Value(now),
        ),
      );
    });
  }

  Future<void> cancel({
    required int workspaceId,
    required String sessionId,
    String? closedByUserId,
  }) {
    return _db.transaction(() async {
      final session = await (_db.select(
        _db.localSessions,
      )..where((t) => t.localId.equals(sessionId))).getSingleOrNull();
      if (session == null) return;
      final now = DateTime.now();
      await (_db.update(
        _db.localSessions,
      )..where((t) => t.localId.equals(sessionId))).write(
        LocalSessionsCompanion(
          status: const Value('cancelled'),
          closedAt: Value(now),
          closedByUserId: Value(closedByUserId),
          updatedAt: Value(now),
        ),
      );
      await (_db.update(
        _db.localTables,
      )..where((t) => t.localId.equals(session.tableLocalId))).write(
        LocalTablesCompanion(
          status: const Value('available'),
          updatedAt: Value(now),
        ),
      );
    });
  }
}
