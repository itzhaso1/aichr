import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../local_db/app_database.dart';
import '../local_db/local_ids.dart';
import 'sync_queue_repository.dart';

/// Local-first customers for POS. Offline create/update → sync_queue → Laravel.
class CustomersRepository {
  CustomersRepository(
    this._db,
    this._queue, {
    String Function()? newId,
  }) : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final SyncQueueRepository _queue;
  final String Function() _newId;

  Future<List<Map<String, dynamic>>> list({
    required int workspaceId,
    String query = '',
    int limit = 50,
  }) async {
    if (workspaceId <= 0) return const [];
    final q = query.trim().toLowerCase();
    final rows = await (_db.select(_db.localCustomers)
          ..where((t) => t.workspaceId.equals(workspaceId))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(limit))
        .get();
    final mapped = rows.map(_toDisplay).where((c) {
      if (q.isEmpty) return true;
      final name = '${c['name']}'.toLowerCase();
      final phone = '${c['phone'] ?? ''}'.toLowerCase();
      return name.contains(q) || phone.contains(q);
    }).toList();
    return mapped;
  }

  Future<Map<String, dynamic>> createOffline({
    required int workspaceId,
    required String deviceId,
    required String name,
    required String phone,
    String? clientReference,
  }) async {
    if (workspaceId <= 0) throw ArgumentError('workspaceId required');
    if (deviceId.trim().isEmpty) throw ArgumentError('deviceId required');
    final key = (clientReference ?? _newId()).trim();
    if (key.isEmpty) throw ArgumentError('clientReference required');

    final existing = await (_db.select(_db.localCustomers)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) & t.localId.equals(key)))
        .getSingleOrNull();
    if (existing != null) return _toDisplay(existing);

    final byPhone = await (_db.select(_db.localCustomers)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) &
              t.phone.equals(phone.trim())))
        .getSingleOrNull();
    if (byPhone != null) return _toDisplay(byPhone);

    final now = DateTime.now();
    final payload = {
      'name': name.trim(),
      'phone': phone.trim(),
      'client_reference': key,
    };

    await _db.transaction(() async {
      await _db.into(_db.localCustomers).insert(
            LocalCustomersCompanion.insert(
              localId: key,
              workspaceId: workspaceId,
              name: name.trim(),
              phone: Value(phone.trim()),
              payloadJson: Value(jsonEncode(payload)),
              updatedAt: now,
              syncStatus: const Value('pending'),
            ),
          );
      await _queue.enqueue(
        workspaceId: workspaceId,
        deviceId: deviceId.trim(),
        entityType: 'customer',
        entityId: key,
        operation: 'create',
        payload: payload,
        clientReference: key,
      );
    });

    final row = await (_db.select(_db.localCustomers)
          ..where((t) => t.localId.equals(key)))
        .getSingle();
    return _toDisplay(row);
  }

  Future<bool> updateOffline({
    required int workspaceId,
    required String deviceId,
    required String localId,
    required String name,
    required String phone,
  }) async {
    final row = await (_db.select(_db.localCustomers)
          ..where((t) =>
              t.workspaceId.equals(workspaceId) & t.localId.equals(localId)))
        .getSingleOrNull();
    if (row == null) return false;

    final now = DateTime.now();
    final payload = {
      'name': name.trim(),
      'phone': phone.trim(),
      'client_reference': localId,
      if (row.serverId != null) 'server_id': row.serverId,
    };

    await _db.transaction(() async {
      await (_db.update(_db.localCustomers)
            ..where((t) =>
                t.workspaceId.equals(workspaceId) & t.localId.equals(localId)))
          .write(
        LocalCustomersCompanion(
          name: Value(name.trim()),
          phone: Value(phone.trim()),
          payloadJson: Value(jsonEncode(payload)),
          syncStatus: const Value('pending'),
          updatedAt: Value(now),
        ),
      );

      if (row.serverId == null) {
        final updated = await _queue.updateOpenPayload(
          workspaceId: workspaceId,
          entityType: 'customer',
          entityId: localId,
          operation: 'create',
          payload: payload,
        );
        if (!updated) {
          await _queue.enqueue(
            workspaceId: workspaceId,
            deviceId: deviceId.trim(),
            entityType: 'customer',
            entityId: localId,
            operation: 'create',
            payload: payload,
            clientReference: localId,
          );
        }
      } else {
        // Server updates for customers stay online-safe: re-create path uses
        // idempotent POST; pending create covers never-synced rows.
        await _queue.enqueue(
          workspaceId: workspaceId,
          deviceId: deviceId.trim(),
          entityType: 'customer',
          entityId: localId,
          operation: 'create',
          payload: payload,
          clientReference: localId,
        );
      }
    });
    return true;
  }

  Future<void> upsertRemoteSnapshot({
    required int workspaceId,
    required List<Map<String, dynamic>> customers,
  }) async {
    if (workspaceId <= 0) return;
    final now = DateTime.now();
    await _db.transaction(() async {
      for (final raw in customers) {
        final serverId = (raw['id'] as num?)?.toInt();
        if (serverId == null || serverId <= 0) continue;
        final clientRef = '${raw['client_reference'] ?? ''}'.trim();
        final localId = clientRef.isNotEmpty
            ? clientRef
            : LocalIds.customer(workspaceId, serverId);
        final existingPending = await (_db.select(_db.localCustomers)
              ..where((t) =>
                  t.workspaceId.equals(workspaceId) &
                  t.localId.equals(localId) &
                  (t.syncStatus.equals('pending') |
                      t.syncStatus.equals('failed'))))
            .getSingleOrNull();
        if (existingPending != null) continue;
        await _db.into(_db.localCustomers).insertOnConflictUpdate(
              LocalCustomersCompanion.insert(
                localId: localId,
                workspaceId: workspaceId,
                serverId: Value(serverId),
                name: '${raw['name'] ?? ''}',
                phone: Value(raw['phone'] as String?),
                payloadJson: Value(jsonEncode({...raw, 'id': serverId})),
                updatedAt: now,
                syncStatus: const Value('synced'),
              ),
            );
      }
    });
  }

  Map<String, dynamic> _toDisplay(LocalCustomer row) {
    return {
      'id': row.serverId ?? row.localId,
      'local_id': row.localId,
      'server_id': row.serverId,
      'name': row.name,
      'phone': row.phone,
      'client_reference': row.localId,
      'sync_status': row.syncStatus,
      'workspace_id': row.workspaceId,
      'is_local_pending':
          row.syncStatus == 'pending' || row.syncStatus == 'failed',
    };
  }
}
