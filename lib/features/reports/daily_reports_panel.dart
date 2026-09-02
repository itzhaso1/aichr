import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_mode.dart';
import '../../core/network/cashier_link.dart';
import '../../core/offline/offline_store.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';

class DailyReportsPanel extends ConsumerStatefulWidget {
  const DailyReportsPanel({super.key});

  @override
  ConsumerState<DailyReportsPanel> createState() => _DailyReportsPanelState();
}

class _DailyReportsPanelState extends ConsumerState<DailyReportsPanel> {
  Map<String, dynamic>? _data;
  Map<String, dynamic> _liveChannelStats = const {};
  var _loading = true;
  String? _error;
  var _forbidden = false;
  var _stale = false;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
    // Defer to after first frame so providers are ready (avoids blank first paint).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  String get _q => DateFormat('yyyy-MM-dd').format(_date);

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _forbidden = false;
    });

    final workspaceId = ref.read(workspaceIdProvider);
    // Local SQLite report first — never white page offline.
    if (workspaceId != null && workspaceId > 0) {
      try {
        final local = await ref
            .read(localFinanceRepositoryProvider)
            .buildDailyReport(workspaceId: workspaceId, date: _date);
        if (!mounted) return;
        setState(() {
          _data = local;
          _loading = false;
          _stale = true;
          _error = null;
          _forbidden = false;
        });
      } catch (_) {
        // Continue to remote / cache.
      }
    }

    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      if (PosMode.isStandaloneRuntime(
        isLocalMode: session?.isLocalMode == true,
        token: session?.token,
      )) {
        final workspaceId = ref.read(workspaceIdProvider);
        if (workspaceId != null) {
          final local = await ref
              .read(localReportsServiceProvider)
              .daily(workspaceId: workspaceId, date: _date);
          if (!mounted) return;
          setState(() {
            _data = local;
            _loading = false;
            _stale = false;
            _error = null;
          });
        }
        return;
      }
      final api = ref.read(cashierApiProvider);
      final data = await api.get('/reports/daily', query: {'date': _q});
      Map<String, dynamic> live = const {};
      if (ref.read(cashierLinkProvider).isOnline) {
        try {
          final channel = await api.get('/orders/channel-stats');
          if (channel['stats'] is Map) {
            live = Map<String, dynamic>.from(channel['stats'] as Map);
          } else if (channel['channel_stats'] is Map) {
            live = Map<String, dynamic>.from(channel['channel_stats'] as Map);
          }
        } catch (_) {
          // Daily report still usable without live open-counts.
        }
      }
      if (!mounted) return;
      await OfflineStore.instance.cacheDailyReport(_q, data);
      setState(() {
        _data = data;
        _liveChannelStats = live;
        _loading = false;
        _error = null;
        _forbidden = false;
        _stale = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isForbidden) {
        setState(() {
          _loading = false;
          _forbidden = true;
          _error = e.message;
          // Keep any local report already shown.
        });
        return;
      }
      final cached = OfflineStore.instance.readDailyReport(_q);
      setState(() {
        _loading = false;
        _forbidden = false;
        if (_data == null && cached != null) {
          _data = cached;
          _stale = true;
          _error = null;
        } else if (_data == null) {
          _error = e.message;
        } else {
          _stale = true;
          _error = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      final cached = OfflineStore.instance.readDailyReport(_q);
      setState(() {
        _loading = false;
        _forbidden = false;
        if (_data == null && cached != null) {
          _data = cached;
          _stale = true;
          _error = null;
        } else if (_data == null) {
          _error = e.toString();
        } else {
          _stale = true;
          _error = null;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // If permissions arrive after first failed paint, reload once they allow reports.
    ref.listen<Map<String, dynamic>>(cashierPermissionsProvider, (prev, next) {
      final wasDenied = !CashierPermissions.canViewReports(
        CashierPermissions.resolve(
          prev,
          ref.read(authControllerProvider).valueOrNull?.permissions,
        ),
      );
      final nowAllowed = CashierPermissions.canViewReports(
        CashierPermissions.resolve(
          next,
          ref.read(authControllerProvider).valueOrNull?.permissions,
        ),
      );
      if (wasDenied && nowAllowed && _data == null && !_loading) {
        _load();
      }
    });

    if (_loading && _data == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text(
              'جاري تحميل التقرير…',
              style: TextStyle(color: HasimColors.muted),
            ),
          ],
        ),
      );
    }

    if (_forbidden) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: HsEmpty(
          title: 'غير مصرح بعرض التقارير',
          subtitle: 'لا تملك صلاحية reports.view. تواصل مع مدير مساحة العمل.',
        ),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر تحميل التقرير',
          subtitle: _error,
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    }

    if (_data == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'لا توجد بيانات للعرض',
          subtitle: 'اضغط لإعادة تحميل التقرير اليومي.',
          actionLabel: 'تحميل التقرير',
          onAction: _load,
        ),
      );
    }

    try {
      return _buildReportBody();
    } catch (e) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر عرض التقرير',
          subtitle: e.toString(),
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    }
  }

  Widget _buildReportBody() {
    final summary = _asMap(_data?['summary']);
    final channels = _asMap(_data?['channel_stats']);
    final top = _asMaps(_data?['top_items']);
    final byType = _asMaps(_data?['quantity_by_type']);
    final payments = _asMaps(_data?['payment_methods']);
    final invoices = _asMaps(_data?['invoices']);
    final byHour = _asMaps(_data?['sales_by_hour']);
    final customers = _asMaps(_data?['customer_summary']);
    final recentOps = _asMaps(_data?['recent_operations']);
    final closedOrders = _asMaps(_data?['closed_orders']);
    final allOrders = _asMaps(_data?['all_orders']);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'التقارير اليومية',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      _stale
                          ? 'عرض من البيانات المحلية — تُحدَّث عند المزامنة'
                          : 'ملخص يومي من المبيعات والفواتير',
                      style: const TextStyle(
                        fontSize: 11,
                        color: HasimColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked == null) return;
                  setState(() => _date = picked);
                  await _load();
                },
                child: Text(_q),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'إحصائيات الطلبات',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          _channelOverviewCards(
            summary: summary,
            channels: channels,
            live: _liveChannelStats,
          ),
          const SizedBox(height: 16),
          const Text('الملخص', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metric(
                _num(
                  summary['invoice_sales_total'] ?? summary['invoices_total'],
                ).toStringAsFixed(2),
                'إجمالي المبيعات',
                highlight: true,
              ),
              _metric('${_int(summary['invoices_count'])}', 'فواتير'),
              _metric('${_int(summary['orders_count'])}', 'طلبات'),
              _metric('${_int(summary['open_orders_count'])}', 'مفتوحة'),
              _metric('${_int(summary['completed_orders_count'])}', 'مكتملة'),
              _metric('${_int(summary['cancelled_orders_count'])}', 'ملغاة'),
              _metric('${_int(summary['paid_orders_count'])}', 'مدفوعة'),
              _metric('${_int(summary['unpaid_orders_count'])}', 'غير مدفوعة'),
              _metric(
                _num(summary['discount_total']).toStringAsFixed(2),
                'خصومات',
              ),
              _metric(_num(summary['tax_total']).toStringAsFixed(2), 'ضريبة'),
              _metric('${_int(summary['total_quantity'])}', 'كميات'),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'حسب القناة',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metric(
                '${_int(summary['table_orders_count'] ?? channels['table'])}',
                'طاولات',
              ),
              _metric(
                '${_int(summary['takeaway_orders_count'] ?? channels['takeaway'])}',
                'خارجي',
              ),
              _metric(
                '${_int(summary['delivery_orders_count'] ?? channels['delivery'])}',
                'توصيل',
              ),
            ],
          ),
          if (payments.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: HsEmpty(title: 'لا توجد طرق دفع مسجّلة لهذا اليوم.'),
            )
          else ...[
            const SizedBox(height: 16),
            const Text(
              'طرق الدفع',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            for (final row in payments)
              _rowCard(_str(row['method']), '× ${_str(row['orders_count'])}'),
          ],
          if (byType.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'الكميات حسب النوع',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            for (final row in byType)
              _rowCard(
                _str(row['item_type']),
                '× ${_str(row['quantity'])} · ${_num(row['sales']).toStringAsFixed(2)}',
              ),
          ],
          const SizedBox(height: 16),
          const Text(
            'الأصناف الأكثر مبيعًا',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (top.isEmpty)
            const HsEmpty(title: 'لا توجد مبيعات مغلقة لهذا اليوم.')
          else
            for (final item in top)
              _rowCard(
                _str(item['product_name']),
                '× ${_str(item['quantity'])} · ${_num(item['sales']).toStringAsFixed(2)}',
              ),
          const SizedBox(height: 16),
          const Text(
            'المبيعات حسب الساعة',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (byHour.isEmpty)
            const HsEmpty(title: 'لا توجد مبيعات حسب الساعة.')
          else
            for (final row in byHour)
              _rowCard(
                _str(row['hour']),
                '${_str(row['orders_count'])} طلب · ${_num(row['sales_total'] ?? row['total_sales']).toStringAsFixed(2)}',
              ),
          if (customers.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'ملخص العملاء',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            for (final row in customers.take(15))
              _rowCard(
                '${_str(row['customer_name'])} · ${_str(row['customer_phone'])}',
                '${_str(row['orders_count'])} · ${_num(row['total_sales']).toStringAsFixed(2)}',
              ),
          ],
          const SizedBox(height: 16),
          const Text(
            'فواتير اليوم',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (invoices.isEmpty)
            const HsEmpty(title: 'لا توجد فواتير لهذا اليوم.')
          else
            for (final inv in invoices)
              _rowCard(
                '${_str(inv['invoice_number'])} · ${_nestedName(inv['table'])}',
                _num(inv['total_amount']).toStringAsFixed(2),
                highlight: true,
              ),
          const SizedBox(height: 16),
          const Text(
            'الطلبات المغلقة',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (closedOrders.isEmpty)
            const HsEmpty(title: 'لا توجد طلبات مغلقة.')
          else
            for (final order in closedOrders.take(30))
              _rowCard(
                '#${_str(order['order_number'] ?? order['id'])} · ${_nestedName(order['table'], fallback: _str(order['order_type']))}',
                _num(order['total_amount']).toStringAsFixed(2),
              ),
          const SizedBox(height: 16),
          const Text(
            'كل الطلبات',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (allOrders.isEmpty)
            const HsEmpty(title: 'لا توجد طلبات لهذا اليوم.')
          else
            for (final order in allOrders.take(40))
              _rowCard(
                '#${_str(order['order_number'] ?? order['id'])} · ${_str(order['pos_status'])} · ${_str(order['placed_at'])}',
                _num(order['total_amount']).toStringAsFixed(2),
              ),
          const SizedBox(height: 16),
          const Text(
            'آخر العمليات',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (recentOps.isEmpty)
            const HsEmpty(title: 'لا توجد عمليات مسجّلة.')
          else
            for (final log in recentOps)
              _rowCard(
                '${_str(log['action'])} · ${_str(log['entity_type'])} #${_str(log['entity_id'])}',
                '${_nestedName(log['user'], fallback: 'النظام')} · ${_str(log['occurred_at'])}',
              ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _channelOverviewCards({
    required Map<String, dynamic> summary,
    required Map<String, dynamic> channels,
    required Map<String, dynamic> live,
  }) {
    final cards = <(String, int, int, bool)>[
      (
        'اليوم · داخل المطعم (طاولة)',
        _int(
          summary['table_orders_count'] ?? channels['table'] ?? live['table'],
        ),
        _int(live['open_table']),
        false,
      ),
      (
        'اليوم · طلب خارجي',
        _int(
          summary['takeaway_orders_count'] ??
              channels['takeaway'] ??
              live['takeaway'],
        ),
        _int(live['open_takeaway']),
        false,
      ),
      (
        'اليوم · توصيل',
        _int(
          summary['delivery_orders_count'] ??
              channels['delivery'] ??
              live['delivery'],
        ),
        _int(live['open_delivery']),
        false,
      ),
      (
        'إجمالي طلبات اليوم',
        _int(summary['orders_count'] ?? live['total']),
        _int(live['open_total'] ?? summary['open_orders_count']),
        true,
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth.isFinite
            ? c.maxWidth
            : MediaQuery.sizeOf(context).width;
        final cols = maxW >= 900
            ? 4
            : maxW >= 520
            ? 2
            : 1;
        final width = cols == 1 ? maxW : (maxW - (8 * (cols - 1))) / cols;
        final cardW = width.isFinite && width > 0 ? width : maxW;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final card in cards)
              SizedBox(
                width: cardW,
                child: HsCard(
                  color: card.$4
                      ? const Color(0xFFECFDF5)
                      : HasimColors.surface,
                  borderColor: card.$4
                      ? const Color(0xFFA7F3D0)
                      : HasimColors.border,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.$1,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: card.$4
                              ? HasimColors.ctaDark
                              : HasimColors.muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${card.$2}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: card.$4
                              ? const Color(0xFF065F46)
                              : HasimColors.ink,
                        ),
                      ),
                      Text(
                        'مفتوحة الآن: ${card.$3}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: card.$4
                              ? HasimColors.ctaDark
                              : HasimColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  List<Map<String, dynamic>> _asMaps(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  num _num(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value) ?? 0;
    return 0;
  }

  int _int(dynamic value) => _num(value).toInt();

  String _str(dynamic value) {
    if (value == null) return '—';
    final s = value.toString().trim();
    return s.isEmpty ? '—' : s;
  }

  String _nestedName(dynamic value, {String fallback = '—'}) {
    if (value is Map) {
      final name = value['name'];
      if (name != null && '$name'.trim().isNotEmpty) return '$name';
    }
    return fallback;
  }

  Widget _metric(String value, String label, {bool highlight = false}) {
    return SizedBox(
      width: 108,
      child: HsCard(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          children: [
            Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: highlight ? HasimColors.ctaDark : HasimColors.ink,
              ),
            ),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: HasimColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowCard(String title, String trailing, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: HsCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              trailing,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: highlight ? HasimColors.ctaDark : HasimColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
