import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/cashier_api.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../../core/widgets/pos_tap.dart';

class DailyReportsPanel extends ConsumerStatefulWidget {
  const DailyReportsPanel({super.key, this.active = true});

  final bool active;

  @override
  ConsumerState<DailyReportsPanel> createState() => _DailyReportsPanelState();
}

class _DailyReportsPanelState extends ConsumerState<DailyReportsPanel> {
  Map<String, dynamic>? _data;
  Map<String, dynamic> _liveChannelStats = const {};
  var _loading = true;
  String? _error;
  var _forbidden = false;
  late DateTime _date;
  Future<void>? _inflight;
  var _pendingReload = false;
  var _reloadScheduled = false;

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
    // Defer to after first frame so providers are ready (avoids blank first paint).
    _scheduleReload();
  }

  @override
  void didUpdateWidget(covariant DailyReportsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _scheduleReload();
    }
  }

  String get _q => DateFormat('yyyy-MM-dd').format(_date);

  void _scheduleReload() {
    if (_reloadScheduled) return;
    _reloadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadScheduled = false;
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (!mounted || picked == null) return;
    setState(() => _date = picked);
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (_inflight != null) {
      _pendingReload = true;
      return;
    }
    final run = _runLoad();
    _inflight = run;
    try {
      await run;
    } finally {
      _inflight = null;
      if (_pendingReload && mounted) {
        _pendingReload = false;
        await _load();
      }
    }
  }

  Future<void> _runLoad() async {
    if (!mounted) return;
    final showSpinner = _data == null;
    if (showSpinner || _error != null || _forbidden) {
      setState(() {
        if (showSpinner) _loading = true;
        _error = null;
        _forbidden = false;
      });
    }

    final workspaceId = ref.read(workspaceIdProvider);
    var resolvedWorkspace = workspaceId;
    if (resolvedWorkspace == null || resolvedWorkspace <= 0) {
      final store = await ref.read(localAuthServiceProvider).anyStore();
      resolvedWorkspace = store?.workspaceId;
    }
    if (resolvedWorkspace == null || resolvedWorkspace <= 0) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'لا توجد مساحة عمل محلية.';
      });
      return;
    }

    try {
      Map<String, dynamic> local;
      try {
        local = await ref
            .read(localReportsServiceProvider)
            .daily(
              workspaceId: resolvedWorkspace,
              date: _date,
            )
            .timeout(const Duration(seconds: 5));
      } on Forbidden {
        rethrow;
      } catch (_) {
        local = await ref
            .read(localFinanceRepositoryProvider)
            .buildDailyReport(workspaceId: resolvedWorkspace, date: _date)
            .timeout(const Duration(seconds: 5));
      }
      final summary = asStringKeyedMap(local['summary']);
      final invoiceRows = asMapList(local['invoices']);
      if (invoiceRows.isEmpty && asIntOr(summary['invoices_count']) == 0) {
        final fromFinance = await ref
            .read(localFinanceRepositoryProvider)
            .buildDailyReport(workspaceId: resolvedWorkspace, date: _date)
            .timeout(const Duration(seconds: 5));
        final financeSummary = asStringKeyedMap(fromFinance['summary']);
        if (asMapList(fromFinance['invoices']).isNotEmpty ||
            asIntOr(financeSummary['invoices_count']) > 0) {
          local = fromFinance;
        }
      }
      if (!mounted) return;
      setState(() {
        _data = local;
        _liveChannelStats = const {};
        _loading = false;
        _error = null;
        _forbidden = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _forbidden = e is Forbidden;
        _error = e is Forbidden ? null : 'تعذر تحميل التقرير المحلي: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int?>(workspaceIdProvider, (prev, next) {
      if (next != prev && next != null && next > 0) {
        _scheduleReload();
      }
    });
    ref.listen<int>(invoicesRevisionProvider, (prev, next) {
      if (prev != next) _scheduleReload();
    });

    Widget body;
    if (_loading && _data == null) {
      body = const Center(
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
    } else if (_forbidden) {
      body = const Padding(
        padding: EdgeInsets.all(16),
        child: HsEmpty(
          title: 'غير مصرح بعرض التقارير',
          subtitle: 'لا تملك صلاحية reports.view. تواصل مع مدير مساحة العمل.',
        ),
      );
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر تحميل التقرير',
          subtitle: _error,
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    } else if (_data == null) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'لا توجد بيانات للعرض',
          subtitle: 'اضغط لإعادة تحميل التقرير اليومي.',
          actionLabel: 'تحميل التقرير',
          onAction: _load,
        ),
      );
    } else {
      try {
        body = _buildReportBody();
      } catch (e) {
        body = Padding(
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

    return SizedBox.expand(
      child: ColoredBox(color: HasimColors.page, child: body),
    );
  }

  Widget _buildReportBody() {
    final summary = asStringKeyedMap(_data?['summary']);
    final channels = asStringKeyedMap(_data?['channel_stats']);
    final top = asMapList(_data?['top_items']);
    final byType = asMapList(_data?['quantity_by_type']);
    final payments = asMapList(_data?['payment_methods']);
    final invoices = asMapList(_data?['invoices']);
    final byHour = asMapList(_data?['sales_by_hour']);
    final customers = asMapList(_data?['customer_summary']);
    final recentOps = asMapList(_data?['recent_operations']);
    final closedOrders = asMapList(_data?['closed_orders']);
    final allOrders = asMapList(_data?['all_orders']);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'التقارير اليومية',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'ملخص يومي من المبيعات والفواتير المحلية',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: HasimColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PosTap(
                onTap: _pickDate,
                child: ConstrainedBox(
                  key: const ValueKey('reports-date-chip'),
                  constraints: const BoxConstraints(minWidth: 88, minHeight: 36),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: HasimColors.surface,
                      borderRadius: BorderRadius.circular(HasimRadius.sm),
                      border: Border.all(color: HasimColors.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        _q,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: HasimColors.ink,
                        ),
                      ),
                    ),
                  ),
                ),
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
                '${_channelCount(summary, channels, 'table')}',
                'طاولات',
              ),
              _metric(
                '${_channelCount(summary, channels, 'takeaway')}',
                'خارجي',
              ),
              _metric(
                '${_channelCount(summary, channels, 'delivery')}',
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
              _rowCard(
                _str(row['method']),
                '× ${_str(row['orders_count'] ?? row['count'])}',
              ),
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
                '${_str(inv['invoice_number'])} · ${nestedName(inv['table'])}',
                asDoubleOr(inv['total_amount']).toStringAsFixed(2),
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
                '#${_str(order['order_number'] ?? order['id'])} · ${nestedName(order['table'], fallback: _str(order['order_type']))}',
                asDoubleOr(order['total_amount']).toStringAsFixed(2),
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
                _str(
                  log['label'] ??
                      '${_str(log['action'])} · ${_str(log['entity_type'])} #${_str(log['entity_id'])}',
                ),
                '${nestedName(log['user'], fallback: 'النظام')} · ${_str(log['occurred_at'] ?? log['at'])}',
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
        _channelCount(summary, channels, 'table', live: live),
        asIntOr(live['open_table']),
        false,
      ),
      (
        'اليوم · طلب خارجي',
        _channelCount(summary, channels, 'takeaway', live: live),
        asIntOr(live['open_takeaway']),
        false,
      ),
      (
        'اليوم · توصيل',
        _channelCount(summary, channels, 'delivery', live: live),
        asIntOr(live['open_delivery']),
        false,
      ),
      (
        'إجمالي طلبات اليوم',
        asIntOr(summary['orders_count'] ?? live['total']),
        asIntOr(live['open_total'] ?? summary['open_orders_count']),
        true,
      ),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final card in cards)
          SizedBox(
            width: 240,
            child: HsCard(
              color: card.$4 ? const Color(0xFFECFDF5) : HasimColors.surface,
              borderColor: card.$4
                  ? const Color(0xFFA7F3D0)
                  : HasimColors.border,
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
  }

  /// Channel count may be a bare int or `{orders_count: n}` from local SQLite.
  int _channelCount(
    Map<String, dynamic> summary,
    Map<String, dynamic> channels,
    String key, {
    Map<String, dynamic>? live,
  }) {
    final fromSummary = summary['${key}_orders_count'];
    if (fromSummary != null) return asIntOr(fromSummary);
    final raw = channels[key] ?? live?[key];
    if (raw is Map) {
      return asIntOr(raw['orders_count'] ?? raw['count'] ?? raw['total']);
    }
    return asIntOr(raw);
  }

  num _num(dynamic value) => asDoubleOr(value);

  int _int(dynamic value) => asIntOr(value);

  String _str(dynamic value) {
    if (value == null) return '—';
    final s = value.toString().trim();
    return s.isEmpty ? '—' : s;
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
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                trailing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: highlight ? HasimColors.ctaDark : HasimColors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
