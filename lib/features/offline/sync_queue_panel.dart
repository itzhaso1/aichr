import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/local_db/workspace_scope.dart';
import '../../core/sync/pos_sync_coordinator.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Visible sync queue backed by SQLite sync_queue_items (not Hive).
class SyncQueuePanel extends ConsumerStatefulWidget {
  const SyncQueuePanel({super.key});

  @override
  ConsumerState<SyncQueuePanel> createState() => _SyncQueuePanelState();
}

class _SyncQueuePanelState extends ConsumerState<SyncQueuePanel> {
  List<Map<String, dynamic>> _records = const [];
  var _busy = false;
  String? _cursor;
  String? _deviceId;
  int _failed = 0;
  int _pending = 0;
  DateTime? _lastSyncAt;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null) {
      setState(() => _records = const []);
      return;
    }
    final rows = await ref
        .read(syncQueueRepositoryProvider)
        .recentForPanel(workspaceId: workspaceId);
    final counts =
        await ref.read(syncQueueRepositoryProvider).counts(workspaceId);
    final db = ref.read(appDatabaseProvider);
    final cursor = await db.readCursor(workspaceId);
    final lastPush = await db.readMetaTime(workspaceId, SyncMetaKeys.lastPushAt);
    final lastPull = await db.readMetaTime(workspaceId, SyncMetaKeys.lastPullAt);
    DateTime? last;
    if (lastPush != null && lastPull != null) {
      last = lastPush.isAfter(lastPull) ? lastPush : lastPull;
    } else {
      last = lastPush ?? lastPull;
    }
    if (!mounted) return;
    setState(() {
      _records = rows;
      _cursor = cursor;
      _deviceId = ref.read(deviceIdHeaderProvider);
      _failed = counts.failed;
      _pending = counts.waiting;
      _lastSyncAt = last;
    });
  }

  String _label(String? status) => switch (status) {
        'pending' => 'Pending',
        'syncing' => 'Syncing',
        'synced' => 'Synced',
        'failed' => 'Failed',
        'cancelled' => 'Cancelled',
        _ => status ?? '—',
      };

  Color _bg(String? status) => switch (status) {
        'pending' => HasimColors.warningSoft,
        'syncing' => HasimColors.brandSoft,
        'synced' => HasimColors.ctaSoft,
        'failed' => HasimColors.dangerSoft,
        _ => HasimColors.navIdleBg,
      };

  Color _fg(String? status) => switch (status) {
        'pending' => HasimColors.warning,
        'syncing' => HasimColors.brandDark,
        'synced' => HasimColors.ctaDark,
        'failed' => HasimColors.danger,
        _ => HasimColors.ink,
      };

  Future<void> _flush() async {
    setState(() => _busy = true);
    final workspaceId = ref.read(workspaceIdProvider);
    final deviceId =
        await ref.read(deviceIdentityProvider).getOrCreateDeviceId();
    await ref.read(posSyncCoordinatorProvider).flushPendingOrders(
          workspaceId: workspaceId,
          deviceId: deviceId,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    await _reload();
  }

  Future<void> _retry(Map<String, dynamic> row) async {
    final localId = '${row['local_id'] ?? ''}';
    final id = row['id'];
    if (id is int) {
      await ref.read(syncQueueRepositoryProvider).requeueFailed(id);
    }
    if (localId.isEmpty) return;
    setState(() => _busy = true);
    final workspaceId = ref.read(workspaceIdProvider);
    final deviceId =
        await ref.read(deviceIdentityProvider).getOrCreateDeviceId();
    await ref.read(posSyncCoordinatorProvider).retryOne(
          localId,
          workspaceId: workspaceId,
          deviceId: deviceId,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'طابور المزامنة',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              HsPrimaryButton(
                label: _busy ? 'جاري…' : 'مزامنة الكل',
                loading: _busy,
                onPressed: _busy ? null : _flush,
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'الطلبات المحلية لا تُحذف عند الفشل. Idempotency عبر UUID العملية تمنع التكرار.',
            style: TextStyle(fontSize: 12, color: HasimColors.muted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'الجهاز: ${_deviceId ?? '—'}  ·  المؤشر: ${_cursor ?? '0'}\n'
            'بانتظار: $_pending  ·  فشل: $_failed  ·  آخر مزامنة: ${_lastSyncAt?.toLocal().toString().substring(0, 16) ?? '—'}',
            style: const TextStyle(fontSize: 12, color: HasimColors.muted, height: 1.4),
          ),
        ),
        Expanded(
          child: _records.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: HsEmpty(title: 'لا توجد عمليات مزامنة محفوظة.'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final row = _records[index];
                    final status = row['status'] as String?;
                    final payload = row['payload'];
                    final itemsCount = payload is Map && payload['items'] is List
                        ? (payload['items'] as List).length
                        : 0;
                    return HsCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${row['entity_type']}/${row['operation']} · ${row['client_reference']}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _bg(status),
                                  borderRadius:
                                      BorderRadius.circular(HasimRadius.sm),
                                ),
                                child: Text(
                                  _label(status),
                                  style: TextStyle(
                                    color: _fg(status),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'أصناف: $itemsCount · محاولات: ${row['attempts'] ?? 0}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: HasimColors.muted,
                            ),
                          ),
                          if (row['last_error'] != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${row['last_error']}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: HasimColors.danger,
                              ),
                            ),
                          ],
                          if (status == 'failed' || status == 'pending') ...[
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: _busy ? null : () => _retry(row),
                                child: const Text('إعادة المحاولة'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
