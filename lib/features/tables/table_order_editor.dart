import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_db/local_db_providers.dart';
import '../../core/api/cashier_api.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../cart/cart_controller.dart';

/// Order editor — local-pending mutates SQLite; synced orders enqueue sync_queue.
class TableOrderEditorDialog extends ConsumerStatefulWidget {
  const TableOrderEditorDialog({
    super.key,
    required this.order,
    this.localPending = false,
  });

  final Map<String, dynamic> order;
  final bool localPending;

  @override
  ConsumerState<TableOrderEditorDialog> createState() =>
      _TableOrderEditorDialogState();
}

class _TableOrderEditorDialogState
    extends ConsumerState<TableOrderEditorDialog> {
  late List<_EditLine> _lines;
  late final TextEditingController _notes;
  late final TextEditingController _discount;
  var _saving = false;
  String? _error;
  List<Map<String, dynamic>> _catalog = const [];

  @override
  void initState() {
    super.initState();
    final items = widget.order['items'] is List
        ? (widget.order['items'] as List).whereType<Map>()
        : const Iterable<Map>.empty();
    _lines = items
        .map(
          (e) => _EditLine(
            // Local unsynced items use String local_id as `id` — never cast to num.
            id: asInt(e['id']),
            menuItemId: asInt(e['pos_menu_item_id']),
            name:
                '${e['product_name'] ?? e['name'] ?? 'صنف'}${e['variant_name'] != null ? ' - ${e['variant_name']}' : ''}',
            quantity: asIntOr(e['quantity'], 1).clamp(1, 9999),
            unitPrice: asDoubleOr(e['unit_price']),
            discount: asDoubleOr(e['discount_amount']),
            remove: false,
          ),
        )
        .toList();
    _notes = TextEditingController(text: '${widget.order['notes'] ?? ''}');
    _discount = TextEditingController(
      text: asDoubleOr(widget.order['discount_amount']).toStringAsFixed(2),
    );
    _loadCatalog();
  }

  @override
  void dispose() {
    _notes.dispose();
    _discount.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    final workspaceId = ref.read(workspaceIdProvider);
    List<Map<String, dynamic>> local = const [];
    if (workspaceId != null && workspaceId > 0) {
      local = await ref.read(catalogRepositoryProvider).products(workspaceId);
    }
    if (!mounted) return;
    if (local.isNotEmpty) {
      setState(() => _catalog = local);
      return;
    }
    setState(
      () => _catalog = ref.read(catalogItemsProvider).valueOrNull ?? const [],
    );
  }

  double get _subtotal {
    var sum = 0.0;
    for (final line in _lines) {
      if (line.remove) continue;
      sum += (line.quantity * line.unitPrice) - line.discount;
    }
    return sum.clamp(0, double.infinity);
  }

  double get _discountAmount =>
      double.tryParse(_discount.text.trim())?.clamp(0, double.infinity) ?? 0;

  double get _taxRate {
    final bootstrapTax = ref.read(cartControllerProvider).taxRate;
    return bootstrapTax.clamp(0, 100).toDouble();
  }

  double get _tax {
    final taxable = (_subtotal - _discountAmount).clamp(0, double.infinity);
    return taxable * (_taxRate / 100);
  }

  double get _total =>
      (_subtotal - _discountAmount + _tax).clamp(0, double.infinity);

  Future<void> _addProduct() async {
    if (_catalog.isEmpty) {
      setState(() => _error = 'لا توجد أصناف متاحة للإضافة.');
      return;
    }
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.55,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'إضافة منتج',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _catalog.length,
                    itemBuilder: (context, index) {
                      final item = _catalog[index];
                      final available = item['is_available'] != false &&
                          item['is_active'] != false;
                      return ListTile(
                        enabled: available,
                        title: Text('${item['name']}'),
                        subtitle: Text(
                          ((asDoubleOr(item['price']))).toStringAsFixed(2),
                        ),
                        onTap: available
                            ? () => Navigator.pop(ctx, item)
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    setState(() {
      _lines.add(
        _EditLine(
          id: null,
          menuItemId: asInt(selected['id']),
          name: '${selected['name']}',
          quantity: 1,
          unitPrice: asDoubleOr(selected['price']),
          discount: 0,
          remove: false,
        ),
      );
    });
  }

  Future<void> _save() async {
    final active = _lines.where((l) => !l.remove).toList();
    if (active.isEmpty) {
      setState(() => _error = 'يجب الإبقاء على صنف واحد على الأقل، أو احذف الطلب بالكامل.');
      return;
    }
    final canDiscount = CashierPermissions.canDiscount(
      ref.read(cashierPermissionsProvider),
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    if (widget.localPending) {
      final localItems = [
        for (final line in _lines)
          if (!line.remove && line.menuItemId != null)
            {
              'pos_menu_item_id': line.menuItemId,
              'name': line.name,
              'quantity': line.quantity,
              'unit_price': line.unitPrice,
              'total_amount': line.quantity * line.unitPrice,
            },
      ];
      if (!mounted) return;
      Navigator.pop(context, {
        'local_pending': true,
        'notes': _notes.text.trim(),
        'items': localItems,
      });
      return;
    }
    final payload = <String, dynamic>{
      'notes': _notes.text.trim(),
      if (canDiscount) 'discount_amount': _discountAmount,
      'items': [
        for (final line in _lines)
          if (line.id != null)
            {
              'id': line.id,
              'quantity': line.quantity,
              'unit_price': line.unitPrice,
              'discount_amount': line.discount,
              'remove': line.remove,
            }
          else if (!line.remove && line.menuItemId != null)
            {
              'pos_menu_item_id': line.menuItemId,
              'quantity': line.quantity,
              'unit_price': line.unitPrice,
            },
      ],
    };
    if (!mounted) return;
    Navigator.pop(context, {
      'enqueue_synced_update': true,
      'payload': payload,
      'notes': _notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final canDiscount = CashierPermissions.canDiscount(
      ref.watch(cashierPermissionsProvider),
    );
    final size = MediaQuery.sizeOf(context);
    // Dialog measures with loose/unbounded height — Expanded needs a TIGHT height.
    final dialogHeight = (size.height * 0.85).clamp(420.0, 720.0);
    final dialogWidth = size.width >= 560 ? 520.0 : size.width - 24;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HasimRadius.lg),
      ),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'تعديل الطلب #${widget.order['order_number'] ?? widget.order['id']}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < _lines.length; i++)
                      if (!_lines[i].remove)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              border: Border.all(color: HasimColors.border),
                              borderRadius:
                                  BorderRadius.circular(HasimRadius.md),
                              color: HasimColors.surfaceSoft,
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _lines[i].name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => setState(() {
                                        if (_lines[i].id != null) {
                                          _lines[i].remove = true;
                                        } else {
                                          _lines.removeAt(i);
                                        }
                                      }),
                                      child: const Text(
                                        'حذف',
                                        style: TextStyle(
                                          color: HasimColors.danger,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      onPressed: _lines[i].quantity <= 1
                                          ? null
                                          : () => setState(
                                                () => _lines[i].quantity--,
                                              ),
                                      icon: const Icon(Icons.remove_circle_outline),
                                    ),
                                    Text(
                                      '${_lines[i].quantity}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 16,
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () => setState(
                                        () => _lines[i].quantity++,
                                      ),
                                      icon: const Icon(Icons.add_circle_outline),
                                    ),
                                    const Spacer(),
                                    Text(
                                      (_lines[i].quantity * _lines[i].unitPrice)
                                          .toStringAsFixed(2),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    HsOutlineButton(
                      label: '+ إضافة منتج',
                      onPressed: _addProduct,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _notes,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'ملاحظات الطلب',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _discount,
                      enabled: canDiscount,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: canDiscount
                            ? 'الخصم (مبلغ)'
                            : 'الخصم (غير مسموح)',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _money('المجموع الفرعي', _subtotal),
                    _money('الخصم', _discountAmount),
                    _money('الضريبة', _tax),
                    _money('الإجمالي', _total, bold: true),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(
                          color: HasimColors.danger,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: HsOutlineButton(
                      label: 'إلغاء',
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: HsPrimaryButton(
                      label: _saving ? 'جاري الحفظ…' : 'حفظ التعديلات',
                      onPressed: _saving ? null : _save,
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

  Widget _money(String label, double value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
              fontSize: bold ? 14 : 12,
            ),
          ),
          const Spacer(),
          Text(
            value.toStringAsFixed(2),
            style: TextStyle(
              fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
              fontSize: bold ? 14 : 12,
              color: bold ? HasimColors.ctaDark : HasimColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _EditLine {
  _EditLine({
    required this.id,
    required this.menuItemId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.discount,
    required this.remove,
  });

  final int? id;
  final int? menuItemId;
  final String name;
  int quantity;
  final double unitPrice;
  final double discount;
  bool remove;
}
