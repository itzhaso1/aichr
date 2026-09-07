import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/printing/printer_service.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../../core/widgets/pos_tap.dart';

/// Closed cashier invoices — local SQLite first, remote enrichment optional.
class InvoicesList extends ConsumerStatefulWidget {
  const InvoicesList({super.key, this.active = true});

  final bool active;

  @override
  ConsumerState<InvoicesList> createState() => _InvoicesListState();
}

class _InvoicesListState extends ConsumerState<InvoicesList> {
  List<Map<String, dynamic>> _invoices = const [];
  var _loading = true;
  String? _error;
  DateTime? _dateFilter;
  Map<String, dynamic>? _selected;
  String? _workspaceName;
  StreamSubscription? _watchSub;

  Map<String, dynamic> get _invoicePerms => CashierPermissions.resolve(
    ref.read(cashierPermissionsProvider),
    ref.read(authControllerProvider).valueOrNull?.permissions,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subscribe();
      _load();
    });
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _watchSub?.cancel();
    _watchSub = ref.read(localFinanceRepositoryProvider).watchInvoices().listen(
      (_) {
        if (mounted) _load(silent: true);
      },
    );
  }

  @override
  void didUpdateWidget(covariant InvoicesList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _load();
    }
  }

  String get _dateQuery => _dateFilter == null
      ? 'كل الفواتير'
      : DateFormat('yyyy-MM-dd').format(_dateFilter!);

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
        _selected = null;
      });
    }
    final workspaceId = ref.read(workspaceIdProvider);
    final finance = ref.read(localFinanceRepositoryProvider);
    final session = ref.read(authControllerProvider).valueOrNull;

    try {
      final local = await finance
          .listInvoices(
            workspaceId: workspaceId,
            onDate: _dateFilter,
            fallbackAllWorkspaces: true,
          )
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _invoices = local;
        _loading = false;
        _error = null;
        _workspaceName = session?.workspace?['name'] as String? ?? 'متجر محلي';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذر تحميل الفواتير المحلية: $e';
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateFilter ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _dateFilter = picked);
    await _load();
  }

  Future<void> _openInvoice(Map<String, dynamic> invoice) async {
    try {
      final workspaceId = ref.read(workspaceIdProvider);
      final localId = '${invoice['local_id'] ?? ''}'.trim();
      Map<String, dynamic>? local;
      if (localId.isNotEmpty) {
        local = await ref
            .read(localFinanceRepositoryProvider)
            .getInvoice(workspaceId: workspaceId, localId: localId);
      }
      if (!mounted) return;
      final draft = Map<String, dynamic>.from(local ?? invoice);
      draft['store_name'] = _workspaceName ?? 'كاشير حاسم';
      setState(() => _selected = draft);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر فتح الفاتورة: $e')));
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
            result.printed
                ? (reprint ? 'تمت إعادة الطباعة.' : 'تمت الطباعة.')
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

  Future<void> _editSelected() async {
    final inv = _selected;
    if (inv == null) return;
    final localId = '${inv['local_id'] ?? ''}'.trim();
    if (localId.isEmpty) return;
    final notes = TextEditingController(text: '${inv['notes'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل الفاتورة'),
        content: TextField(
          controller: notes,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'ملاحظات'),
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
    final trimmed = notes.text.trim();
    notes.dispose();
    if (ok != true) return;
    try {
      await ref
          .read(localFinanceRepositoryProvider)
          .updateInvoice(
            localId: localId,
            notes: trimmed,
            permissions: _invoicePerms,
          );
      await _openInvoice({'local_id': localId});
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم تعديل الفاتورة.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PosException ? e.messageAr : '$e')),
      );
    }
  }

  Future<void> _deleteSelected() async {
    final inv = _selected;
    if (inv == null) return;
    final localId = '${inv['local_id'] ?? ''}'.trim();
    if (localId.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 72, vertical: 24),
        backgroundColor: HasimColors.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'حذف الفاتورة',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  'سيتم حذف الفاتورة ${inv['invoice_number'] ?? ''} نهائياً.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: HasimColors.muted,
                  ),
                ),
                const SizedBox(height: 16),
                HsPrimaryButton(
                  label: 'حذف',
                  onPressed: () => Navigator.pop(ctx, true),
                ),
                const SizedBox(height: 8),
                HsOutlineButton(
                  label: 'إلغاء',
                  onPressed: () => Navigator.pop(ctx, false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(localFinanceRepositoryProvider)
          .deleteInvoice(localId: localId, permissions: _invoicePerms);
      ref.read(invoicesRevisionProvider.notifier).state++;
      if (!mounted) return;
      setState(() => _selected = null);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم حذف الفاتورة.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PosException ? e.messageAr : '$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int?>(workspaceIdProvider, (prev, next) {
      if (next != prev && next != null && next > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_load(silent: true));
        });
      }
    });
    ref.listen<int>(invoicesRevisionProvider, (prev, next) {
      if (prev != next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_load(silent: true));
        });
      }
    });
    try {
      return _buildBody();
    } catch (e) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر عرض الفواتير',
          subtitle: '$e',
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    }
  }

  Widget _buildBody() {
    if (_selected != null) {
      return _InvoiceDetail(
        invoice: _selected!,
        onBack: () => setState(() => _selected = null),
        onPrint: () => _printSelected(reprint: false),
        onReprint: () => _printSelected(reprint: true),
        onEdit: CashierPermissions.canEditInvoices(_invoicePerms)
            ? _editSelected
            : null,
        onDelete: CashierPermissions.canDeleteInvoices(_invoicePerms)
            ? _deleteSelected
            : null,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded =
            constraints.hasBoundedHeight &&
            constraints.maxHeight.isFinite &&
            constraints.maxHeight > 0;
        final list = RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _header()),
              if (_loading && _invoices.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null && _invoices.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: HsEmpty(
                      title: 'تعذر تحميل الفواتير',
                      subtitle: _error,
                      actionLabel: 'إعادة المحاولة',
                      onAction: _load,
                    ),
                  ),
                )
              else if (_invoices.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: HsEmpty(
                      title: 'لا توجد فواتير بعد.',
                      subtitle:
                          'بعد الدفع أو إغلاق الطاولة تظهر الفاتورة هنا تلقائياً. اضغط عليها لفتحها. لا يوجد خيار فتح في الإعدادات.',
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  sliver: SliverToBoxAdapter(
                    child: HsSoftGrid(
                      minTileWidth: 300,
                      maxColumns: 3,
                      children: [
                        for (final inv in _invoices) _invoiceCard(inv),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
        if (!bounded) {
          return SizedBox(
            height: MediaQuery.sizeOf(context).height,
            width: constraints.hasBoundedWidth && constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width,
            child: list,
          );
        }
        return list;
      },
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'فواتير الكاشير',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          const Text(
            'هذه فواتير مكتملة (مدفوعة). اضغط على الفاتورة لفتحها وطباعتها — ليس من الإعدادات.',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: HasimColors.muted),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              HsActionChip(
                label: _dateQuery,
                icon: Icons.calendar_today,
                onTap: _pickDate,
              ),
              if (_dateFilter != null)
                HsActionChip(
                  label: 'الكل',
                  onTap: () async {
                    setState(() => _dateFilter = null);
                    await _load();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _invoiceCard(Map<String, dynamic> inv) {
    return HsCard(
      child: PosTap(
        onTap: () => _openInvoice(inv),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${inv['invoice_number'] ?? inv['local_id'] ?? '—'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      inv['table'] != null
                          ? 'طاولة: ${nestedName(inv['table'])}'
                          : 'فاتورة مكتملة · اضغط للعرض',
                      style: const TextStyle(
                        fontSize: 12,
                        color: HasimColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                asDoubleOr(inv['total_amount']).toStringAsFixed(2),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvoiceDetail extends StatelessWidget {
  const _InvoiceDetail({
    required this.invoice,
    required this.onBack,
    required this.onPrint,
    required this.onReprint,
    this.onEdit,
    this.onDelete,
  });

  final Map<String, dynamic> invoice;
  final VoidCallback onBack;
  final VoidCallback onPrint;
  final VoidCallback onReprint;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

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
            PosTap(
              onTap: onBack,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.arrow_forward),
              ),
            ),
            Expanded(
              child: Text(
                'فاتورة ${invoice['invoice_number'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            HsActionChip(label: 'طباعة', onTap: onPrint),
            HsActionChip(label: 'إعادة', onTap: onReprint),
            if (onEdit != null) HsActionChip(label: 'تعديل', onTap: onEdit!),
            if (onDelete != null)
              HsActionChip(
                label: 'حذف',
                color: HasimColors.danger,
                onTap: onDelete!,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('${invoice['store_name'] ?? 'كاشير حاسم'}'),
        Text(
          'التاريخ: ${invoice['closed_at'] ?? invoice['created_at'] ?? '—'}',
        ),
        Text('الطاولة: ${nestedName(invoice['table'])}'),
        if (payment != null) Text('الدفع: $payment'),
        if (invoice['notes'] != null && '${invoice['notes']}'.trim().isNotEmpty)
          Text('ملاحظات: ${invoice['notes']}'),
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
