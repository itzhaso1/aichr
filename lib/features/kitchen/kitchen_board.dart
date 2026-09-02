import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/config/app_config.dart';
import '../../core/network/cashier_link.dart';
import '../../core/offline/offline_store.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_labels.dart';
import '../../core/pos/pos_mode.dart';
import '../../core/realtime/pos_event_source.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Kitchen prep board — mirrors `workspace/pos/kitchen/index`.
class KitchenBoard extends ConsumerStatefulWidget {
  const KitchenBoard({super.key});

  @override
  ConsumerState<KitchenBoard> createState() => _KitchenBoardState();
}

class _KitchenBoardState extends ConsumerState<KitchenBoard> {
  List<Map<String, dynamic>> _orders = const [];
  var _loading = true;
  String? _error;
  PollingPosEventSource? _source;

  static const _statusOptions = [
    'new',
    'accepted',
    'preparing',
    'ready',
    'delivered',
    'completed',
    'cancelled',
  ];

  @override
  void initState() {
    super.initState();
    _load();
    _startPolling();
  }

  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }

  Future<void> _startPolling() async {
    _source = PollingPosEventSource(
      interval: Duration(seconds: AppConfig.kitchenPollSeconds),
      enabled: () => ref.read(cashierLinkProvider).isOnline,
      poll: () async {
        await _load(silent: true);
        return const <PosEvent>[];
      },
    );
    await _source!.start();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId != null && workspaceId > 0) {
      await for (final local
          in ref
              .read(kitchenLocalServiceProvider)
              .watchActive(workspaceId)
              .take(1)) {
        if (!mounted) return;
        setState(() {
          _orders = local;
          _loading = false;
          _error = null;
        });
      }
    }
    final session = ref.read(authControllerProvider).valueOrNull;
    if (session?.isLocalMode == true ||
        PosMode.isStandaloneToken(session?.token)) {
      return;
    }
    try {
      final data = await ref.read(cashierApiProvider).get('/kitchen/orders');
      final list = <Map<String, dynamic>>[];
      if (data['orders'] is List) {
        for (final item in data['orders'] as List) {
          if (item is Map) list.add(Map<String, dynamic>.from(item));
        }
      }
      if (!mounted) return;
      await OfflineStore.instance.cacheKitchen(list);
      if (list.isNotEmpty) {
        setState(() {
          _orders = list;
          _loading = false;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (!mounted || silent) return;
      if (_orders.isEmpty) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (!mounted || silent) return;
      if (_orders.isEmpty) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _updateStatus(String localId, String status) async {
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null) return;
    try {
      await ref
          .read(kitchenLocalServiceProvider)
          .updateStatus(
            workspaceId: workspaceId,
            orderLocalId: localId,
            status: status,
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر تحميل المطبخ',
          subtitle: _error,
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'طلبات التجهيز للطاولات',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 4),
              Text(
                'كل طلب مرتبط بطاولة يظهر هنا ليتم تجهيزه ومتابعة حالته.',
                style: TextStyle(fontSize: 12, color: HasimColors.muted),
              ),
            ],
          ),
        ),
        Expanded(
          child: _orders.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: HsEmpty(title: 'لا توجد طلبات تجهيز حالياً.'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final order = _orders[index];
                      final current = order['pos_status'] as String? ?? 'new';
                      final items = order['items'] is List
                          ? (order['items'] as List).whereType<Map>()
                          : const Iterable<Map>.empty();
                      return HsCard(
                        color: HasimColors.surfaceSoft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${order['table']?['name'] ?? 'طاولة غير معروفة'}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                        ),
                                      ),
                                      Text(
                                        'طلب #${order['order_number'] ?? order['id']} · ${order['created_at'] ?? ''}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: HasimColors.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (items.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              for (final item in items)
                                Text(
                                  '• ${item['quantity']} × ${item['item_name'] ?? item['product_name']}'
                                  '${item['variant_name'] != null ? ' - ${item['variant_name']}' : ''}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                            ],
                            if (order['notes'] != null &&
                                (order['notes'] as String).isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(
                                    HasimRadius.sm,
                                  ),
                                ),
                                child: Text(
                                  'ملاحظات: ${order['notes']}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(
                                        color: HasimColors.border,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        HasimRadius.sm,
                                      ),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        isExpanded: true,
                                        value: _statusOptions.contains(current)
                                            ? current
                                            : 'new',
                                        items: [
                                          for (final s in _statusOptions)
                                            DropdownMenuItem(
                                              value: s,
                                              child: Text(
                                                PosLabels.status(s),
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                        ],
                                        onChanged: (v) {
                                          final localId =
                                              order['local_id'] as String? ??
                                              order['id']?.toString();
                                          if (v != null &&
                                              localId != null &&
                                              localId.isNotEmpty) {
                                            _updateStatus(localId, v);
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
