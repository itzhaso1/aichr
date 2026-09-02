import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../domain/pricing_service.dart';
import '../pos_errors.dart';
import '../pos_permissions.dart';

class ShiftService {
  ShiftService(this._db, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final String Function() _newId;

  Future<LocalShift?> currentOpen(int workspaceId) {
    return (_db.select(_db.localShifts)
          ..where(
            (t) => t.workspaceId.equals(workspaceId) & t.status.equals('open'),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<String> open({
    required int workspaceId,
    required String userId,
    required double openingCash,
    Map<String, dynamic>? permissions,
  }) {
    PosPermissions.require(permissions, PosPermissions.shiftOpen);
    return _db.transaction(() async {
      final open = await currentOpen(workspaceId);
      if (open != null) return open.localId;
      final id = _newId();
      final now = DateTime.now();
      await _db
          .into(_db.localShifts)
          .insert(
            LocalShiftsCompanion.insert(
              localId: id,
              workspaceId: workspaceId,
              userId: Value(userId),
              openedAt: now,
              openingCash: Value(Money.toCents(openingCash)),
            ),
          );
      await _db
          .into(_db.localCashMovements)
          .insert(
            LocalCashMovementsCompanion.insert(
              localId: _newId(),
              workspaceId: workspaceId,
              shiftLocalId: id,
              type: 'opening',
              amount: Money.toCents(openingCash),
              reason: const Value('افتتاح الصندوق'),
              createdByUserId: Value(userId),
              createdAt: now,
            ),
          );
      return id;
    });
  }

  Future<Map<String, double>> expectedBreakdown(String shiftId) async {
    final rows = await (_db.select(
      _db.localCashMovements,
    )..where((t) => t.shiftLocalId.equals(shiftId))).get();
    var opening = 0;
    var sales = 0;
    var cashIn = 0;
    var refunds = 0;
    var cashOut = 0;
    var expenses = 0;
    for (final row in rows) {
      final cents = row.amount;
      switch (row.type) {
        case 'opening':
          opening += cents;
        case 'sale':
          sales += cents;
        case 'cash_in':
          cashIn += cents;
        case 'refund':
          refunds += cents;
        case 'cash_out':
          cashOut += cents;
        case 'expense':
          expenses += cents;
      }
    }
    final expected = opening + sales + cashIn - refunds - cashOut - expenses;
    return {
      'opening': Money.fromCents(opening),
      'sales': Money.fromCents(sales),
      'cash_in': Money.fromCents(cashIn),
      'refunds': Money.fromCents(refunds),
      'cash_out': Money.fromCents(cashOut),
      'expenses': Money.fromCents(expenses),
      'expected': Money.fromCents(expected),
    };
  }

  Future<void> addMovement({
    required int workspaceId,
    required String shiftId,
    required String type,
    required double amount,
    String? reason,
    String? userId,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.cashMovement);
    if (amount < 0) throw const InvalidDiscount();
    final open = await currentOpen(workspaceId);
    if (open == null || open.localId != shiftId) throw const ShiftNotOpen();
    await _db
        .into(_db.localCashMovements)
        .insert(
          LocalCashMovementsCompanion.insert(
            localId: _newId(),
            workspaceId: workspaceId,
            shiftLocalId: shiftId,
            type: type,
            amount: Money.toCents(amount),
            reason: Value(reason),
            createdByUserId: Value(userId),
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<Map<String, dynamic>> close({
    required int workspaceId,
    required String shiftId,
    required double actualCash,
    Map<String, dynamic>? permissions,
  }) {
    PosPermissions.require(permissions, PosPermissions.shiftClose);
    return _db.transaction(() async {
      final shift =
          await (_db.select(_db.localShifts)..where(
                (t) =>
                    t.localId.equals(shiftId) &
                    t.workspaceId.equals(workspaceId),
              ))
              .getSingleOrNull();
      if (shift == null || shift.status != 'open') throw const ShiftNotOpen();
      final breakdown = await expectedBreakdown(shiftId);
      final expected = breakdown['expected'] ?? 0;
      final diff = Money.fromCents(
        Money.toCents(actualCash) - Money.toCents(expected),
      );
      final now = DateTime.now();
      await _db
          .into(_db.localCashMovements)
          .insert(
            LocalCashMovementsCompanion.insert(
              localId: _newId(),
              workspaceId: workspaceId,
              shiftLocalId: shiftId,
              type: 'closing',
              amount: Money.toCents(actualCash),
              reason: const Value('إغلاق الصندوق'),
              createdByUserId: Value(shift.userId),
              createdAt: now,
            ),
          );
      await (_db.update(
        _db.localShifts,
      )..where((t) => t.localId.equals(shiftId))).write(
        LocalShiftsCompanion(
          status: const Value('closed'),
          closedAt: Value(now),
          closingCash: Value(Money.toCents(actualCash)),
          expectedCash: Value(Money.toCents(expected)),
          actualCash: Value(Money.toCents(actualCash)),
          difference: Value(Money.toCents(diff)),
        ),
      );
      return {
        ...breakdown,
        'actual': actualCash,
        'difference': diff,
        'shift_id': shiftId,
      };
    });
  }
}
