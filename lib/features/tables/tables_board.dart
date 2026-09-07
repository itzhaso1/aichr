import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/config/app_config.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/network/cashier_link.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/pos/pos_labels.dart';
import '../../core/realtime/pos_event_source.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../../core/widgets/pos_tap.dart';
import 'table_detail_screen.dart';
import 'table_workspace.dart';

/// Tables board — Local DB first via [TablesRepository]. No UI offline branching.
class TablesBoard extends ConsumerStatefulWidget {
  const TablesBoard({super.key});

  @override
  ConsumerState<TablesBoard> createState() => _TablesBoardState();
}

class _TablesBoardState extends ConsumerState<TablesBoard> {
  List<Map<String, dynamic>> _tables = const [];
  var _loading = true;
  String? _error;
  PollingPosEventSource? _source;

  @override
  void initState() {
    super.initState();
    _load();
    _startPolling();
  }

  @override
  void dispose() {
    _source?.dispose();
    _source = null;
    super.dispose();
  }

  Future<void> _startPolling() async {
    _source?.dispose();
    _source = PollingPosEventSource(
      interval: Duration(seconds: AppConfig.tablesPollSeconds),
      // Polling is a sync concern — UI still loads Local DB without this.
      enabled: () => ref.read(cashierLinkProvider).isOnline,
      poll: () async {
        if (!mounted || ref.read(openTableIdProvider) != null) {
          return const <PosEvent>[];
        }
        await _load(silent: true);
        return const <PosEvent>[];
      },
    );
    await _source!.start();
  }

  Future<void> _load({bool silent = false}) async {
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _tables = const [];
        _error = silent ? null : 'لا توجد مساحة عمل محددة.';
      });
      return;
    }

    final repo = ref.read(tablesRepositoryProvider);

    // 1) Local SQLite first — works with internet fully offline.
    final local = await repo.listTables(workspaceId);
    if (!mounted) return;
    if (local.isNotEmpty) {
      setState(() {
        _tables = local;
        _loading = false;
        _error = null;
      });
    } else if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    // 2) Repository best-effort remote refresh (no UI if-offline).
    final next = await repo.loadBoard(workspaceId);
    if (!mounted) return;
    if (silent && _sameBoardSnapshot(_tables, next)) {
      if (_loading) setState(() => _loading = false);
      return;
    }
    setState(() {
      _tables = next;
      _loading = false;
      _error = next.isEmpty
          ? (AppConfig.offlineOnly
              ? 'لا توجد طاولات بعد. اضغط «إضافة طاولة» بالأعلى.'
              : 'لا توجد طاولات محفوظة محليًا. أكمل Initial Sync مرة واحدة وأنت متصل.')
          : null;
    });
  }

  bool _sameBoardSnapshot(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> next,
  ) {
    if (current.length != next.length) return false;
    for (var i = 0; i < current.length; i++) {
      final a = current[i];
      final b = next[i];
      if (a['id'] != b['id'] ||
          a['status'] != b['status'] ||
          a['session_id'] != b['session_id'] ||
          a['open_orders_count'] != b['open_orders_count'] ||
          a['orders_count'] != b['orders_count'] ||
          a['total'] != b['total'] ||
          a['name'] != b['name']) {
        return false;
      }
    }
    return true;
  }

  Future<void> _addTable() async {
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد مساحة عمل محددة.')),
      );
      return;
    }
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('طاولة جديدة'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'اسم / رقم الطاولة'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    final trimmed = name.text.trim();
    name.dispose();
    if (ok != true || trimmed.isEmpty) return;
    try {
      await ref.read(catalogAdminServiceProvider).createTable(
            workspaceId: workspaceId,
            name: trimmed,
            permissions: CashierPermissions.resolve(
              ref.read(cashierPermissionsProvider),
              ref.read(authControllerProvider).valueOrNull?.permissions,
            ),
          );
      ref.invalidate(localTablesProvider);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تمت إضافة «$trimmed».')),
      );
    } catch (e) {
      if (!mounted) return;
      final message = e is PosException ? e.messageAr : '$e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إضافة الطاولة: $message')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final openId = ref.watch(openTableIdProvider);
    if (openId != null) {
      return TableDetailScreen(key: ValueKey('table-$openId'), tableId: openId);
    }

    if (_loading && _tables.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _tables.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر تحميل الطاولات',
          subtitle: _error,
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final crossAxis = width >= 1100
        ? 5
        : width >= 800
            ? 4
            : width >= 520
                ? 3
                : 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الطاولات',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                    ),
                    Text(
                      'اضغط على الطاولة للدخول إلى تفاصيلها وعملياتها',
                      style: TextStyle(fontSize: 11, color: HasimColors.muted),
                    ),
                  ],
                ),
              ),
              PosTap(
                onTap: _addTable,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, color: HasimColors.brand),
                      SizedBox(width: 4),
                      Text(
                        'إضافة طاولة',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: HasimColors.brand,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PosTap(
                onTap: _load,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.refresh),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _tables.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: HsEmpty(
                    title: 'لا توجد طاولات بعد.',
                    subtitle: 'أضف طاولة من هنا أو من الإعدادات ثم اضغط حفظ.',
                    actionLabel: 'إضافة طاولة',
                    onAction: _addTable,
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxis,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.15,
                    ),
                    itemCount: _tables.length,
                    itemBuilder: (context, index) =>
                        _tableCard(_tables[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _tableCard(Map<String, dynamic> table) {
    final occupied = table['status'] == 'occupied';
    final hasSession = table['session_id'] != null;
    final total = asDoubleOr(table['total']);
    final orders = asIntOr(table['open_orders_count'] ?? table['orders_count']);
    final id = asInt(table['id']);
    final localId = '${table['local_id'] ?? ''}'.trim();
    if (id == null && localId.isEmpty) {
      return const SizedBox.shrink();
    }

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(HasimRadius.md),
      child: PosTap(
        onTap: id == null ? null : () => openTableWorkspace(ref, id),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HasimRadius.md),
            border: Border.all(
              color: occupied ? HasimColors.occupied : HasimColors.border,
              width: occupied ? 1.4 : 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${table['name']}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_left,
                        color: HasimColors.muted,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  occupied
                      ? HsBadge.occupied(
                          PosLabels.tableStatus(table['status'] as String?),
                        )
                      : HsBadge.available(
                          PosLabels.tableStatus(table['status'] as String?),
                        ),
                  const SizedBox(height: 6),
                  Text(
                    hasSession ? 'جلسة مفتوحة' : 'مغلقة',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: hasSession ? HasimColors.ink : HasimColors.muted,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'الطلبات: $orders',
                    style: const TextStyle(
                      fontSize: 12,
                      color: HasimColors.muted,
                    ),
                  ),
                  if (total > 0)
                    Text(
                      'الإجمالي: ${total.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: HasimColors.ctaDark,
                      ),
                    ),
                  const SizedBox(height: 4),
                  const Text(
                    'اضغط للدخول',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: HasimColors.brand,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
