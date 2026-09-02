import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/pos/pos_mode.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/printing/printer_service.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Closed cashier invoices — local SQLite first, remote enrichment optional.
class InvoicesList extends ConsumerStatefulWidget {
  const InvoicesList({super.key});

  @override
  ConsumerState<InvoicesList> createState() => _InvoicesListState();
}

class _InvoicesListState extends ConsumerState<InvoicesList> {
  List<Map<String, dynamic>> _invoices = const [];
  var _loading = true;
  String? _error;
  late DateTime _date;
  Map<String, dynamic>? _selected;
  String? _workspaceName;
  var _stale = false;

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  String get _dateQuery => DateFormat('yyyy-MM-dd').format(_date);

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
    });
    final workspaceId = ref.read(workspaceIdProvider);
    final finance = ref.read(localFinanceRepositoryProvider);

    // Local first — never white-screen offline.
    if (workspaceId != null && workspaceId > 0) {
      try {
        final local = await finance.listInvoices(
          workspaceId: workspaceId,
          onDate: _date,
        );
        if (!mounted) return;
        if (local.isNotEmpty) {
          setState(() {
            _invoices = local;
            _loading = false;
            _stale = true;
            _error = null;
          });
        }
      } catch (_) {
        // Continue to remote / empty state.
      }
    }

    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      if (PosMode.isStandaloneRuntime(
        isLocalMode: session?.isLocalMode == true,
        token: session?.token,
      )) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _stale = false;
          _workspaceName =
              session?.workspace?['name'] as String? ?? 'متجر محلي';
        });
        return;
      }
      final boot = await ref.read(cashierApiProvider).get('/bootstrap');
      final data = await ref
          .read(cashierApiProvider)
          .get('/invoices', query: {'date': _dateQuery});
      final list = asMapList(data['invoices']);
      if (!mounted) return;
      setState(() {
        if (list.isNotEmpty || _invoices.isEmpty) {
          _invoices = list.isNotEmpty ? list : _invoices;
        }
        _loading = false;
        _stale = false;
        _error = null;
        final ws = asStringKeyedMap(boot['workspace']);
        _workspaceName = ws['name']?.toString() ?? _workspaceName;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_invoices.isEmpty) {
          _error = e.message;
        } else {
          _stale = true;
          _error = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_invoices.isEmpty) {
          _error = e.toString();
        } else {
          _stale = true;
          _error = null;
        }
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _date = picked);
    await _load();
  }

  Future<void> _openInvoice(Map<String, dynamic> invoice) async {
    try {
      final workspaceId = ref.read(workspaceIdProvider);
      final localId = '${invoice['local_id'] ?? ''}';
      Map<String, dynamic>? local;
      if (workspaceId != null && localId.isNotEmpty) {
        local = await ref
            .read(localFinanceRepositoryProvider)
            .getInvoice(workspaceId: workspaceId, localId: localId);
      }
      final session = ref.read(authControllerProvider).valueOrNull;
      final serverId = asInt(invoice['id'] ?? invoice['server_id']);
      if (serverId != null &&
          serverId > 0 &&
          !PosMode.isStandaloneRuntime(
            isLocalMode: session?.isLocalMode == true,
            token: session?.token,
          )) {
        try {
          final data = await ref
              .read(cashierApiProvider)
              .get('/invoices/$serverId');
          if (!mounted) return;
          final inv = data['invoice'] is Map
              ? Map<String, dynamic>.from(data['invoice'] as Map)
              : Map<String, dynamic>.from(data);
          inv['store_name'] = _workspaceName ?? 'كاشير حاسم';
          setState(() => _selected = inv);
          return;
        } catch (_) {
          // Fall through to local draft.
        }
      }
      if (!mounted) return;
      final draft = Map<String, dynamic>.from(local ?? invoice);
      draft['store_name'] = _workspaceName ?? 'كاشير حاسم';
      setState(() => _selected = draft);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر فتح الفاتورة: $e')),
      );
    }
  }

  Future<void> _printSelected({required bool reprint}) async {
    final inv = _selected;
    if (inv == null) return;
    try {
      final printer = await ref.read(printerServiceFutureProvider.future);
      final result = await printer.printInvoice(inv);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reprint
                ? (result.success ? 'تمت إعادة الطباعة.' : result.message)
                : result.message,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر الطباعة: $e')));
    }
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'فواتير الكاشير المغلقة',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _stale
                          ? 'عرض محلي — ستُحدَّث عند عودة الاتصال'
                          : 'فاتورة مستقلة عن نظام الفوترة الخارجي.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: HasimColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(_dateQuery),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading && _invoices.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _invoices.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: HsEmpty(
                    title: 'تعذر تحميل الفواتير',
                    subtitle: _error,
                    actionLabel: 'إعادة المحاولة',
                    onAction: _load,
                  ),
                )
              : _invoices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: HsEmpty(
                    title: 'لا توجد فواتير لهذا التاريخ.',
                    subtitle:
                        'الفواتير المحلية تظهر هنا بعد إغلاق الطاولة أو طلب خارجي.',
                  ),
                )
              : _selected != null
              ? _InvoiceDetail(
                  invoice: _selected!,
                  onBack: () => setState(() => _selected = null),
                  onPrint: () => _printSelected(reprint: false),
                  onReprint: () => _printSelected(reprint: true),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _invoices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final inv = _invoices[index];
                      return HsCard(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _openInvoice(inv),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${inv['invoice_number'] ?? inv['local_id'] ?? '—'}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        inv['table'] != null
                                            ? 'طاولة: ${nestedName(inv['table'])}'
                                            : (inv['is_local'] == true
                                                  ? 'محلية — بانتظار المزامنة'
                                                  : 'فاتورة'),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: HasimColors.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  asDoubleOr(
                                    inv['total_amount'],
                                  ).toStringAsFixed(2),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
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

class _InvoiceDetail extends StatelessWidget {
  const _InvoiceDetail({
    required this.invoice,
    required this.onBack,
    required this.onPrint,
    required this.onReprint,
  });

  final Map<String, dynamic> invoice;
  final VoidCallback onBack;
  final VoidCallback onPrint;
  final VoidCallback onReprint;

  @override
  Widget build(BuildContext context) {
    final items = asMapList(invoice['items']);
    final tax = invoice['tax_amount'];
    final payment = invoice['payment_method'];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_forward),
            ),
            Expanded(
              child: Text(
                'فاتورة ${invoice['invoice_number'] ?? ''}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            OutlinedButton(onPressed: onPrint, child: const Text('طباعة')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onReprint, child: const Text('إعادة')),
          ],
        ),
        const SizedBox(height: 8),
        Text('${invoice['store_name'] ?? 'كاشير حاسم'}'),
        Text(
          'التاريخ: ${invoice['closed_at'] ?? invoice['created_at'] ?? '—'}',
        ),
        Text('الطاولة: ${nestedName(invoice['table'])}'),
        if (payment != null) Text('الدفع: $payment'),
        const Divider(),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${item['item_name'] ?? item['product_name'] ?? item['name'] ?? 'صنف'} × ${item['quantity'] ?? 1}',
                  ),
                ),
                Text(asDoubleOr(item['total_amount']).toStringAsFixed(2)),
              ],
            ),
          ),
        const Divider(),
        _row('المجموع الفرعي', invoice['subtotal']),
        _row('الخصم', invoice['discount_amount']),
        if (tax != null) _row('الضريبة', tax),
        _row('الإجمالي', invoice['total_amount'], bold: true),
      ],
    );
  }

  Widget _row(String label, dynamic value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            asDoubleOr(value).toStringAsFixed(2),
            style: TextStyle(
              fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
