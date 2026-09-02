import 'package:flutter/material.dart';

import '../../core/pos/application/checkout_service.dart';
import '../../core/pos/domain/pricing_service.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';

class PaymentSheetResult {
  const PaymentSheetResult({required this.payments});

  final List<PaymentTender> payments;
}

Future<PaymentSheetResult?> showPaymentSheet({
  required BuildContext context,
  required double total,
}) {
  return showModalBottomSheet<PaymentSheetResult>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _PaymentSheet(total: total),
    ),
  );
}

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.total});

  final double total;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _Line {
  _Line({this.method = 'cash', this.amount = 0});

  String method;
  double amount;
  double? tendered;
}

class _PaymentSheetState extends State<_PaymentSheet> {
  late final List<_Line> _lines;

  @override
  void initState() {
    super.initState();
    _lines = [_Line(method: 'cash', amount: widget.total)];
  }

  double get _paid =>
      Money.round(_lines.fold<double>(0, (s, l) => s + l.amount));

  double get _remaining => Money.round(widget.total - _paid);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'الدفع',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text('الإجمالي: ${widget.total.toStringAsFixed(2)}'),
            Text('المتبقي: ${_remaining.toStringAsFixed(2)}'),
            const SizedBox(height: 12),
            for (var i = 0; i < _lines.length; i++) _row(i),
            TextButton.icon(
              onPressed: () => setState(() {
                _lines.add(
                  _Line(
                    method: 'card',
                    amount: _remaining > 0 ? _remaining : 0,
                  ),
                );
              }),
              icon: const Icon(Icons.add),
              label: const Text('إضافة طريقة دفع'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: HasimColors.brand),
              onPressed: () {
                Navigator.pop(
                  context,
                  PaymentSheetResult(
                    payments: [
                      for (final l in _lines)
                        if (l.amount > 0)
                          PaymentTender(
                            method: l.method,
                            amount: Money.round(l.amount),
                            tendered: l.method == 'cash' ? l.tendered : null,
                          ),
                    ],
                  ),
                );
              },
              child: const Text('تأكيد الدفع'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(int index) {
    final line = _lines[index];
    final change =
        line.method == 'cash' &&
            line.tendered != null &&
            line.tendered! >= line.amount
        ? Money.round(line.tendered! - line.amount)
        : 0.0;
    return HsCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: line.method,
                  items: const [
                    DropdownMenuItem(value: 'cash', child: Text('نقد')),
                    DropdownMenuItem(value: 'card', child: Text('بطاقة')),
                    DropdownMenuItem(value: 'bank', child: Text('تحويل بنكي')),
                    DropdownMenuItem(value: 'credit', child: Text('آجل')),
                    DropdownMenuItem(value: 'other', child: Text('أخرى')),
                  ],
                  onChanged: (v) => setState(() => line.method = v ?? 'cash'),
                ),
              ),
              if (_lines.length > 1)
                IconButton(
                  onPressed: () => setState(() => _lines.removeAt(index)),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          TextFormField(
            key: ValueKey('pay-amount-$index-${line.method}'),
            initialValue: line.amount.toStringAsFixed(2),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'المبلغ'),
            onChanged: (v) =>
                setState(() => line.amount = double.tryParse(v) ?? 0),
          ),
          if (line.method == 'cash') ...[
            TextField(
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'المسلّم (Tendered)',
              ),
              onChanged: (v) => setState(() {
                line.tendered = double.tryParse(v);
                if (line.tendered != null && line.amount <= 0) {
                  line.amount = widget.total;
                }
              }),
            ),
            if (change > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'الباقي: ${change.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
