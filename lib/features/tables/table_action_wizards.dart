import 'package:flutter/material.dart';

import '../../core/pos/pos_labels.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../../core/widgets/pos_tap.dart';

/// Multi-step transfer / merge wizard matching cashier UX expectations.
class TableTransferWizard extends StatefulWidget {
  const TableTransferWizard({
    super.key,
    required this.title,
    required this.currentTableName,
    required this.candidates,
    required this.confirmLabel,
  });

  final String title;
  final String currentTableName;
  final List<Map<String, dynamic>> candidates;
  final String confirmLabel;

  @override
  State<TableTransferWizard> createState() => _TableTransferWizardState();
}

class _TableTransferWizardState extends State<TableTransferWizard> {
  var _step = 0;
  int? _targetId;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogHeight = (size.height * 0.7).clamp(400.0, 560.0);
    final dialogWidth = size.width >= 460 ? 420.0 : size.width - 40;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HasimRadius.lg),
      ),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              _StepDots(step: _step, total: 3),
              const SizedBox(height: 16),
              Expanded(child: _body()),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_step > 0)
                    Expanded(
                      child: HsOutlineButton(
                        label: 'رجوع',
                        onPressed: () => setState(() => _step -= 1),
                      ),
                    ),
                  if (_step > 0) const SizedBox(width: 8),
                  Expanded(
                    child: HsPrimaryButton(
                      label: _step == 2 ? widget.confirmLabel : 'التالي',
                      onPressed: _onPrimary,
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

  Widget _body() {
    if (_step == 0) {
      return HsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('الطاولة الحالية', style: TextStyle(color: HasimColors.muted)),
            const SizedBox(height: 8),
            Text(
              widget.currentTableName,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            const Icon(Icons.arrow_downward, color: HasimColors.brand),
            const SizedBox(height: 8),
            const Text(
              'في الخطوة التالية اختر الطاولة الجديدة.',
              style: TextStyle(fontSize: 12, color: HasimColors.muted),
            ),
          ],
        ),
      );
    }
    if (_step == 1) {
      if (widget.candidates.isEmpty) {
        return const HsEmpty(title: 'لا توجد طاولات أخرى متاحة.');
      }
      return ListView.separated(
        itemCount: widget.candidates.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final t = widget.candidates[index];
          final id = (t['id'] as num).toInt();
          final selected = _targetId == id;
          return Material(
            color: selected ? HasimColors.ctaSoft : Colors.white,
            borderRadius: BorderRadius.circular(HasimRadius.md),
            child: PosTap(
              onTap: () => setState(() => _targetId = id),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(HasimRadius.md),
                  border: Border.all(
                    color: selected ? HasimColors.cta : HasimColors.border,
                    width: selected ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${t['name']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Text(
                      PosLabels.tableStatus(t['status'] as String?),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: t['status'] == 'occupied'
                            ? HasimColors.occupied
                            : HasimColors.available,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }
    final target = widget.candidates.cast<Map<String, dynamic>?>().firstWhere(
          (t) => (t?['id'] as num?)?.toInt() == _targetId,
          orElse: () => null,
        );
    return HsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('تأكيد العملية', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text('من: ${widget.currentTableName}'),
          const SizedBox(height: 8),
          const Icon(Icons.arrow_downward, color: HasimColors.brand),
          const SizedBox(height: 8),
          Text(
            'إلى: ${target?['name'] ?? '—'}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  void _onPrimary() {
    if (_step == 0) {
      setState(() => _step = 1);
      return;
    }
    if (_step == 1) {
      if (_targetId == null) return;
      setState(() => _step = 2);
      return;
    }
    Navigator.pop(context, _targetId);
  }
}

class SplitBillWizard extends StatefulWidget {
  const SplitBillWizard({
    super.key,
    required this.items,
    required this.sessionTotal,
  });

  final List<Map<String, dynamic>> items;
  final double sessionTotal;

  @override
  State<SplitBillWizard> createState() => _SplitBillWizardState();
}

class _SplitBillWizardState extends State<SplitBillWizard> {
  var _step = 0;
  late final List<Map<String, dynamic>> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.items
        .map((e) => Map<String, dynamic>.from(e)..['selected_qty'] = 0)
        .toList();
  }

  double get _selectedTotal {
    var sum = 0.0;
    for (final item in _items) {
      final qty = (item['selected_qty'] as num?)?.toInt() ?? 0;
      final unit = (item['unit_price'] as num?)?.toDouble() ?? 0;
      sum += qty * unit;
    }
    return sum;
  }

  bool get _hasSelection =>
      _items.any((e) => ((e['selected_qty'] as num?) ?? 0) > 0);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogHeight = (size.height * 0.75).clamp(420.0, 620.0);
    final dialogWidth = size.width >= 480 ? 440.0 : size.width - 32;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HasimRadius.lg),
      ),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'تقسيم الحساب',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              _StepDots(step: _step, total: 3),
              const SizedBox(height: 16),
              Expanded(child: _body()),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_step > 0)
                    Expanded(
                      child: HsOutlineButton(
                        label: 'رجوع',
                        onPressed: () => setState(() => _step -= 1),
                      ),
                    ),
                  if (_step > 0) const SizedBox(width: 8),
                  Expanded(
                    child: HsPrimaryButton(
                      label: _step == 2 ? 'تأكيد التقسيم' : 'التالي',
                      onPressed: _onPrimary,
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

  Widget _body() {
    if (_step == 0) {
      return HsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('إجمالي الطلب', style: TextStyle(color: HasimColors.muted)),
            const SizedBox(height: 8),
            Text(
              widget.sessionTotal.toStringAsFixed(2),
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: HasimColors.ctaDark,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'اختر المنتجات والكميات التي تريد فصلها في الخطوة التالية.',
              style: TextStyle(fontSize: 12, color: HasimColors.muted),
            ),
          ],
        ),
      );
    }
    if (_step == 1) {
      return ListView.builder(
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          final max = (item['quantity'] as num).toInt();
          final qty = (item['selected_qty'] as num).toInt();
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: HsCard(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item['name']}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          'المتاح: $max · ${((item['unit_price'] as num?) ?? 0).toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: HasimColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    iconSize: 28,
                    onPressed: qty <= 0
                        ? null
                        : () => setState(() => item['selected_qty'] = qty - 1),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text(
                    '$qty',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  IconButton(
                    iconSize: 28,
                    onPressed: qty >= max
                        ? null
                        : () => setState(() => item['selected_qty'] = qty + 1),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }
    return HsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ملخص التقسيم', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text('قيمة الجزء المفصول: ${_selectedTotal.toStringAsFixed(2)}'),
          const SizedBox(height: 6),
          Text(
            'المتبقي التقريبي: ${(widget.sessionTotal - _selectedTotal).toStringAsFixed(2)}',
          ),
          const SizedBox(height: 12),
          const Text(
            'سيتم إنشاء مجموعة طلب جديدة بالكميات المحددة عبر Laravel.',
            style: TextStyle(fontSize: 12, color: HasimColors.muted),
          ),
        ],
      ),
    );
  }

  void _onPrimary() {
    if (_step == 0) {
      setState(() => _step = 1);
      return;
    }
    if (_step == 1) {
      if (!_hasSelection) return;
      setState(() => _step = 2);
      return;
    }
    final selected = _items
        .where((e) => ((e['selected_qty'] as num?) ?? 0) > 0)
        .map(
          (e) => {
            'order_item_id': e['order_item_id'],
            'quantity': e['selected_qty'],
          },
        )
        .toList();
    Navigator.pop(context, selected);
  }
}

class CloseTableWizard extends StatelessWidget {
  const CloseTableWizard({super.key, required this.tableName});

  final String tableName;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إغلاق الطاولة'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('الطاولة: $tableName'),
          const SizedBox(height: 8),
          const Text(
            'سيتم إغلاق الجلسة وإصدار فاتورة كاشير إن وُجدت طلبات.',
            style: TextStyle(fontSize: 12, color: HasimColors.muted),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: HasimColors.danger),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('تأكيد الإغلاق'),
        ),
      ],
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= step ? HasimColors.brand : HasimColors.border,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          if (i < total - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }
}
