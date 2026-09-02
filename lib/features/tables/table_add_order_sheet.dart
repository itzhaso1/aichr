import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/cashier_api.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/sync/pos_sync_coordinator.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../cart/cart_controller.dart';

/// In-table add-order sheet — Local SQLite first, then sync_queue → Laravel.
/// No invoice / payment / print (those happen only on close table).
class TableAddOrderSheet extends ConsumerStatefulWidget {
  const TableAddOrderSheet({
    super.key,
    required this.tableId,
    required this.tableName,
  });

  final int tableId;
  final String tableName;

  @override
  ConsumerState<TableAddOrderSheet> createState() => _TableAddOrderSheetState();
}

class _TableAddOrderSheetState extends ConsumerState<TableAddOrderSheet> {
  List<Map<String, dynamic>> _catalog = const [];
  List<Map<String, dynamic>> _categories = const [];
  final _lines = <_DraftLine>[];
  final _notes = TextEditingController();
  final _search = TextEditingController();
  int? _categoryId;
  var _loading = true;
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _notes.dispose();
    _search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _cachedCatalog() {
    return ref.read(catalogItemsProvider).valueOrNull ?? const [];
  }

  List<Map<String, dynamic>> _cachedCategories() {
    return ref.read(categoriesProvider).valueOrNull ?? const [];
  }

  void _applyCatalog(
    List<Map<String, dynamic>> items,
    List<Map<String, dynamic>> cats, {
    String? error,
  }) {
    setState(() {
      _catalog = items;
      _categories = cats;
      _loading = false;
      if (items.isEmpty) {
        _error = error ??
            'الكتالوج غير متاح. أكمل المزامنة الأولية أثناء الاتصال.';
      } else {
        _error = error;
      }
    });
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final workspaceId = ref.read(workspaceIdProvider);
    // Always prefer Local SQLite via repository; remote refresh is best-effort.
    if (workspaceId != null && workspaceId > 0) {
      try {
        final catalog = ref.read(catalogRepositoryProvider);
        final localItems = await catalog.products(workspaceId);
        final localCats = await catalog.categories(workspaceId);
        if (localItems.isNotEmpty) {
          if (!mounted) return;
          _applyCatalog(localItems, localCats);
        }
      } catch (_) {}
    }
    try {
      final api = ref.read(cashierApiProvider);
      final itemsData =
          await api.get('/catalog/items', query: {'per_page': 100});
      final catsData = await api.get('/catalog/categories');
      final items = <Map<String, dynamic>>[];
      final cats = <Map<String, dynamic>>[];
      if (itemsData['items'] is List) {
        for (final item in itemsData['items'] as List) {
          if (item is Map) items.add(Map<String, dynamic>.from(item));
        }
      }
      if (catsData['categories'] is List) {
        for (final c in catsData['categories'] as List) {
          if (c is Map) cats.add(Map<String, dynamic>.from(c));
        }
      }
      if (items.isEmpty) {
        items.addAll(_cachedCatalog());
      }
      if (cats.isEmpty) {
        cats.addAll(_cachedCategories());
      }
      if (!mounted) return;
      _applyCatalog(items, cats);
    } catch (e) {
      if (!mounted) return;
      final items = _cachedCatalog();
      final cats = _cachedCategories();
      if (items.isNotEmpty || _catalog.isNotEmpty) {
        if (items.isNotEmpty) {
          _applyCatalog(items, cats);
        } else {
          setState(() => _loading = false);
        }
      } else {
        _applyCatalog(const [], const [], error: e.toString());
      }
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _catalog.where((item) {
      if (item['is_active'] == false) return false;
      if (_categoryId != null &&
          (item['pos_item_category_id'] as num?)?.toInt() != _categoryId) {
        return false;
      }
      if (q.isEmpty) return true;
      final hay =
          '${item['name']}|${item['sku']}|${item['barcode']}|${item['item_type']}'
              .toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  double get _subtotal =>
      _lines.fold<double>(0, (sum, l) => sum + l.quantity * l.unitPrice);

  void _addItem(Map<String, dynamic> item) {
    final id = (item['id'] as num).toInt();
    final existing = _lines.indexWhere((l) => l.menuItemId == id);
    setState(() {
      if (existing >= 0) {
        _lines[existing].quantity++;
      } else {
        _lines.add(
          _DraftLine(
            menuItemId: id,
            name: '${item['name']}',
            unitPrice: (item['price'] as num?)?.toDouble() ?? 0,
            quantity: 1,
          ),
        );
      }
    });
  }

  Future<void> _saveLocal(String key) async {
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      throw StateError('workspace id is required');
    }
    final deviceId =
        await ref.read(deviceIdentityProvider).getOrCreateDeviceId();
    final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();
    await ref.read(ordersRepositoryProvider).createTableOrder(
          workspaceId: workspaceId,
          deviceId: deviceId,
          tableId: widget.tableId,
          clientReference: key,
          notes: notes,
          items: [
            for (final line in _lines)
              {
                'pos_menu_item_id': line.menuItemId,
                'name': line.name,
                'quantity': line.quantity,
                'unit_price': line.unitPrice,
                'total_amount': line.quantity * line.unitPrice,
              },
          ],
        );
  }

  Future<void> _save() async {
    if (_lines.isEmpty) {
      setState(() => _error = 'أضف منتجًا واحدًا على الأقل.');
      return;
    }
    if (_catalog.isEmpty) {
      setState(
        () => _error =
            'الكتالوج غير متاح بدون اتصال. افتح التطبيق وهو متصل لتحميل الأصناف.',
      );
      return;
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      setState(() {
        _error = 'لا توجد مساحة عمل محددة. لا يمكن حفظ الطلب محليًا.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final clientRef = const Uuid().v4();
    try {
      // Local-first: SQLite transaction + sync_queue (works fully offline).
      await _saveLocal(clientRef);
      // Never block the sheet close on network sync.
      // ignore: unawaited_futures
      ref.read(posSyncCoordinatorProvider).flushPendingOrders(
            workspaceId: workspaceId,
          );
      if (!mounted) return;
      Navigator.pop(context, {
        'local_pending': true,
        'client_reference': clientRef,
        'dining_table_id': widget.tableId,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return SafeArea(
      child: SizedBox(
        height: height * 0.92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'إضافة طلب',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'إلى ${widget.tableName} — حفظ فقط بدون فاتورة أو طباعة',
                          style: const TextStyle(
                            fontSize: 11,
                            color: HasimColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'بحث بالاسم / SKU / Barcode',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _chip('الكل', null),
                    for (final c in _categories)
                      if (c['is_active'] != false)
                        _chip(
                          '${c['name']}',
                          (c['id'] as num).toInt(),
                        ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _filtered.isEmpty
                          ? Center(
                              child: Text(
                                _catalog.isEmpty
                                    ? 'الكتالوج غير متاح بدون اتصال. افتح التطبيق وهو متصل لتحميل الأصناف.'
                                    : 'لا توجد منتجات',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: HasimColors.muted),
                              ),
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              itemCount: _filtered.length,
                              itemBuilder: (context, index) {
                                final item = _filtered[index];
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    '${item['name']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                    ),
                                  ),
                                  subtitle: Text(
                                    ((item['price'] as num?) ?? 0)
                                        .toStringAsFixed(2),
                                  ),
                                  trailing: const Icon(Icons.add_circle_outline),
                                  onTap: () => _addItem(item),
                                );
                              },
                            ),
                    ),
                    VerticalDivider(width: 1, color: HasimColors.border),
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                'السلة',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                          Expanded(
                            child: _lines.isEmpty
                                ? const Center(
                                    child: Text(
                                      'اختر منتجات من القائمة',
                                      style: TextStyle(
                                        color: HasimColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: _lines.length,
                                    itemBuilder: (context, index) {
                                      final line = _lines[index];
                                      return ListTile(
                                        dense: true,
                                        title: Text(
                                          line.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                        subtitle: Text(
                                          (line.quantity * line.unitPrice)
                                              .toStringAsFixed(2),
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () => setState(() {
                                                if (line.quantity <= 1) {
                                                  _lines.removeAt(index);
                                                } else {
                                                  line.quantity--;
                                                }
                                              }),
                                              icon: const Icon(
                                                Icons.remove_circle_outline,
                                                size: 20,
                                              ),
                                            ),
                                            Text(
                                              '${line.quantity}',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                            IconButton(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () => setState(
                                                () => line.quantity++,
                                              ),
                                              icon: const Icon(
                                                Icons.add_circle_outline,
                                                size: 20,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: TextField(
                              controller: _notes,
                              maxLines: 2,
                              decoration: const InputDecoration(
                                labelText: 'ملاحظة (اختياري)',
                                isDense: true,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                            child: Row(
                              children: [
                                const Text(
                                  'الإجمالي',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                                const Spacer(),
                                Text(
                                  _subtotal.toStringAsFixed(2),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: HasimColors.ctaDark,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: HasimColors.danger,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: HsPrimaryButton(
                              label: _saving ? 'جاري الحفظ…' : 'حفظ الطلب',
                              onPressed: _saving ? null : _save,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, int? id) {
    final selected = _categoryId == id;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _categoryId = id),
        selectedColor: HasimColors.brand.withValues(alpha: 0.2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HasimRadius.sm),
        ),
      ),
    );
  }
}

class _DraftLine {
  _DraftLine({
    required this.menuItemId,
    required this.name,
    required this.unitPrice,
    required this.quantity,
  });

  final int menuItemId;
  final String name;
  final double unitPrice;
  int quantity;
}
