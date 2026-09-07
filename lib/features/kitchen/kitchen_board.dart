import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_labels.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Kitchen prep board — SQLite `watch()` only (no API polling).
class KitchenBoard extends ConsumerStatefulWidget {
  const KitchenBoard({super.key});

  @override
  ConsumerState<KitchenBoard> createState() => _KitchenBoardState();
}

class _KitchenBoardState extends ConsumerState<KitchenBoard> {
  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  List<Map<String, dynamic>> _orders = const [];
  var _loading = true;
  String? _error;
  int? _workspaceId;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bind());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _bind() async {
    await _sub?.cancel();
    var workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      final store = await ref.read(localAuthServiceProvider).anyStore();
      workspaceId = store?.workspaceId;
    }
    if (!mounted) return;
    if (workspaceId == null || workspaceId <= 0) {
      setState(() {
        _loading = false;
        _error = 'لم يتم إعداد المتجر المحلي بعد.';
        _orders = const [];
      });
      return;
    }
    _workspaceId = workspaceId;
    _sub = ref
        .read(kitchenLocalServiceProvider)
        .watchActive(workspaceId)
        .listen(
          (orders) {
            if (!mounted) return;
            setState(() {
              _orders = orders;
              _loading = false;
              _error = null;
            });
          },
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = e.toString();
            });
          },
        );
  }

  Future<void> _updateStatus(String localId, String status) async {
    final workspaceId = _workspaceId ?? ref.read(workspaceIdProvider);
    if (workspaceId == null) return;
    try {
      await ref
          .read(kitchenLocalServiceProvider)
          .updateStatus(
            workspaceId: workspaceId,
            orderLocalId: localId,
            status: status,
            permissions: ref
                .read(authControllerProvider)
                .valueOrNull
                ?.permissions,
          );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _ticketTitle(Map<String, dynamic> order) {
    return PosLabels.kitchenHeading(
      orderType: order['order_type']?.toString(),
      tableName: nestedName(order['table'], fallback: ''),
    );
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
          onAction: _bind,
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
                'طلبات التجهيز',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 4),
              Text(
                'الطاولات والطلبات الخارجية والتوصيل تظهر هنا للشيف فقط.',
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
                  onRefresh: _bind,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: (_orders.length / 2).ceil(),
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, row) {
                      final left = _orders[row * 2];
                      final rightIndex = row * 2 + 1;
                      final hasRight = rightIndex < _orders.length;
                      return IntrinsicHeight(
                        child: Row(
                          key: ValueKey('kitchen-row-$row'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _ticketCard(left)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: hasRight
                                  ? _ticketCard(_orders[rightIndex])
                                  : const SizedBox.shrink(),
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

  Widget _ticketCard(Map<String, dynamic> order) {
    final current = order['pos_status'] as String? ?? 'new';
    final items = order['items'] is List
        ? (order['items'] as List).whereType<Map>()
        : const Iterable<Map>.empty();
    return HsCard(
      key: ValueKey('kitchen-${order['local_id']}'),
      color: PosLabels.statusSoft(current),
      borderColor: PosLabels.statusColor(current),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _ticketTitle(order),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${orderDisplayLabel(order)} · ${PosLabels.orderType(order['order_type']?.toString())}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: HasimColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              HsBadge(
                label: PosLabels.status(current),
                background: PosLabels.statusSoft(current),
                foreground: PosLabels.statusColor(current),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final item in items)
              Text(
                '• ${item['quantity']} × ${catalogItemName(item)}'
                '${item['notes'] != null && '${item['notes']}'.trim().isNotEmpty ? ' (${item['notes']})' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
          ],
          if (order['notes'] != null &&
              '${order['notes']}'.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: HasimColors.surface,
                borderRadius: BorderRadius.circular(HasimRadius.sm),
              ),
              child: Text(
                'ملاحظات: ${order['notes']}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in _statusOptions)
                HsActionChip(
                  label: PosLabels.status(s),
                  selected: s == current,
                  color: PosLabels.statusColor(s),
                  onTap: () {
                    final localId =
                        order['local_id'] as String? ?? order['id']?.toString();
                    if (localId != null && localId.isNotEmpty) {
                      unawaited(_updateStatus(localId, s));
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
