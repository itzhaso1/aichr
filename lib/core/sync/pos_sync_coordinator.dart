import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/cashier_api.dart';
import '../auth/auth_controller.dart';
import '../local_db/local_db_providers.dart';
import '../offline/pending_order.dart';
import '../offline/sync_engine.dart';
import '../pos/application/pos_providers.dart';
import '../pos/pos_mode.dart';
import 'sync_engine_v2.dart';

/// Primary sync path is SyncEngineV2. Legacy Hive flush runs only to drain
/// leftover pending rows until migration completes (no POS dual-write).
class PosSyncCoordinator {
  PosSyncCoordinator({
    required SyncEngine hiveEngine,
    required SyncEngineV2 sqliteEngine,
    this.allowNetwork = true,
  }) : _hive = hiveEngine,
       _sqlite = sqliteEngine;

  final SyncEngine _hive;
  final SyncEngineV2 _sqlite;
  final bool allowNetwork;

  Future<SyncFlushResult> flushPendingOrders({
    int? workspaceId,
    String? deviceId,
  }) async {
    if (!allowNetwork) {
      return const SyncFlushResult();
    }
    // Drain any pre-Phase-6 Hive leftovers once; SQLite is SoT for POS sync.
    final hive = await _hive.flushPendingOrders(workspaceId: workspaceId);
    if (workspaceId == null || workspaceId <= 0) {
      return hive;
    }
    final sqlite = await _sqlite.syncBidirectional(
      workspaceId: workspaceId,
      deviceId: deviceId,
    );
    return SyncFlushResult(
      synced: hive.synced + sqlite.synced,
      failed: hive.failed + sqlite.failed,
      keptPending: hive.keptPending + sqlite.keptPending,
      authRequired: hive.authRequired || sqlite.authRequired,
      skippedInFlight: hive.skippedInFlight || sqlite.skippedInFlight,
    );
  }

  Future<bool> retryOne(
    String localId, {
    int? workspaceId,
    String? deviceId,
  }) async {
    final hiveOk = await _hive.retryOne(localId, workspaceId: workspaceId);
    if (workspaceId == null || workspaceId <= 0) return hiveOk;
    final sqlite = await _sqlite.syncBidirectional(
      workspaceId: workspaceId,
      deviceId: deviceId,
    );
    return hiveOk || sqlite.synced > 0;
  }
}

final syncEngineV2Provider = Provider<SyncEngineV2>((ref) {
  return SyncEngineV2(
    ref.watch(appDatabaseProvider),
    ref.watch(syncQueueRepositoryProvider),
    api: ref.watch(cashierApiProvider),
    pullApplier: ref.watch(syncPullApplierProvider),
  );
});

final posSyncCoordinatorProvider = Provider<PosSyncCoordinator>((ref) {
  final session = ref.watch(authControllerProvider).valueOrNull;
  final connected = ref.watch(posConnectedModeProvider);
  final standalone =
      session?.isLocalMode == true || PosMode.isStandaloneToken(session?.token);
  return PosSyncCoordinator(
    hiveEngine: ref.watch(syncEngineProvider),
    sqliteEngine: ref.watch(syncEngineV2Provider),
    allowNetwork: !standalone || connected,
  );
});
