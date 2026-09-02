import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_mode.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../cart/cart_controller.dart';

/// Catalog admin — CRUD via `/api/cashier/v1/catalog/*` when `menu.manage`.
class ItemsAdminPanel extends ConsumerStatefulWidget {
  const ItemsAdminPanel({super.key});

  @override
  ConsumerState<ItemsAdminPanel> createState() => _ItemsAdminPanelState();
}

class _ItemsAdminPanelState extends ConsumerState<ItemsAdminPanel> {
  List<Map<String, dynamic>> _items = const [];
  List<Map<String, dynamic>> _categories = const [];
  var _loading = true;
  String? _error;
  final _search = TextEditingController();

  Map<String, dynamic> get _perms => CashierPermissions.resolve(
    ref.read(cashierPermissionsProvider),
    ref.read(authControllerProvider).valueOrNull?.permissions,
  );

  bool get _canManage => CashierPermissions.canManageMenu(_perms);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      final standalone = PosMode.isStandaloneRuntime(
        isLocalMode: session?.isLocalMode == true,
        token: session?.token,
      );
      final workspaceId = ref.read(workspaceIdProvider);
      if (standalone && workspaceId != null) {
        final items = await ref
            .read(catalogRepositoryProvider)
            .products(workspaceId);
        final cats = await ref
            .read(catalogRepositoryProvider)
            .categories(workspaceId);
        if (!mounted) return;
        setState(() {
          _items = items;
          _categories = cats;
          _loading = false;
        });
        ref.invalidate(catalogItemsProvider);
        return;
      }
      final api = ref.read(cashierApiProvider);
      final itemsData = await api.get(
        '/catalog/items',
        query: {
          'active_only': false,
          'per_page': 100,
          'q': _search.text.trim(),
        },
      );
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
      if (!mounted) return;
      setState(() {
        _items = items;
        _categories = cats;
        _loading = false;
      });
      ref.invalidate(catalogItemsProvider);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _editItem({Map<String, dynamic>? existing}) async {
    if (!_canManage) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) =>
          _ItemFormDialog(categories: _categories, existing: existing),
    );
    if (result == null) return;
    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      final workspaceId = ref.read(workspaceIdProvider);
      if (PosMode.isStandaloneRuntime(
            isLocalMode: session?.isLocalMode == true,
            token: session?.token,
          ) &&
          workspaceId != null) {
        final admin = ref.read(catalogAdminServiceProvider);
        if (existing == null) {
          await admin.createProduct(
            workspaceId: workspaceId,
            name: '${result['name']}',
            price: (result['price'] as num?)?.toDouble() ?? 0,
            sku: result['sku'] as String?,
            barcode: result['barcode'] as String?,
            cost: (result['cost'] as num?)?.toDouble() ?? 0,
            taxRate: (result['tax_rate'] as num?)?.toDouble() ?? 0,
            stock: (result['stock'] as num?)?.toInt(),
            trackStock: result['track_stock'] == true,
            categoryLocalId: result['category_local_id'] as String?,
            permissions: session?.permissions ?? _perms,
          );
        } else {
          await admin.updateProduct(
            workspaceId: workspaceId,
            localId: '${existing['local_id'] ?? existing['id']}',
            name: '${result['name']}',
            price: (result['price'] as num?)?.toDouble(),
            sku: result['sku'] as String?,
            barcode: result['barcode'] as String?,
            cost: (result['cost'] as num?)?.toDouble(),
            stock: (result['stock'] as num?)?.toInt(),
            permissions: session?.permissions ?? _perms,
          );
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              existing == null
                  ? 'تمت إضافة الصنف محلياً.'
                  : 'تم تحديث الصنف محلياً.',
            ),
          ),
        );
        await _load();
        return;
      }
      final api = ref.read(cashierApiProvider);
      if (existing == null) {
        await api.post('/catalog/items', data: result);
      } else {
        await api.put('/catalog/items/${existing['id']}', data: result);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            existing == null ? 'تمت إضافة الصنف.' : 'تم تحديث الصنف.',
          ),
        ),
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    if (!_canManage) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الصنف؟'),
        content: Text('${item['name']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: HasimColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      final workspaceId = ref.read(workspaceIdProvider);
      final localId = '${item['local_id'] ?? ''}';
      if (PosMode.isStandaloneRuntime(
            isLocalMode: session?.isLocalMode == true,
            token: session?.token,
          ) &&
          workspaceId != null &&
          localId.isNotEmpty) {
        await ref
            .read(catalogAdminServiceProvider)
            .deleteProduct(
              workspaceId: workspaceId,
              localId: localId,
              permissions: session?.permissions ?? _perms,
            );
        await _load();
        return;
      }
      await ref.read(cashierApiProvider).delete('/catalog/items/${item['id']}');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editCategory({Map<String, dynamic>? existing}) async {
    if (!_canManage) return;
    final name = TextEditingController(text: '${existing?['name'] ?? ''}');
    final active = ValueNotifier<bool>(existing?['is_active'] != false);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'تصنيف جديد' : 'تعديل التصنيف'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'الاسم'),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, v, __) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('نشط'),
                value: v,
                onChanged: (nv) => active.value = nv,
              ),
            ),
          ],
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
    if (ok != true) return;
    final payload = {
      'name': name.text.trim(),
      'is_active': active.value,
      'sort_order': existing?['sort_order'] ?? 0,
    };
    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      final workspaceId = ref.read(workspaceIdProvider);
      if (PosMode.isStandaloneRuntime(
            isLocalMode: session?.isLocalMode == true,
            token: session?.token,
          ) &&
          workspaceId != null) {
        if (existing == null) {
          await ref
              .read(catalogAdminServiceProvider)
              .createCategory(
                workspaceId: workspaceId,
                name: payload['name'] as String,
                permissions: session?.permissions ?? _perms,
              );
        }
        await _load();
        return;
      }
      final api = ref.read(cashierApiProvider);
      if (existing == null) {
        await api.post('/catalog/categories', data: payload);
      } else {
        await api.put('/catalog/categories/${existing['id']}', data: payload);
      }
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _deleteCategory(Map<String, dynamic> category) async {
    if (!_canManage) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف التصنيف؟'),
        content: Text('${category['name']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: HasimColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(cashierApiProvider)
          .delete('/catalog/categories/${category['id']}');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = CashierPermissions.resolve(
      ref.watch(cashierPermissionsProvider),
      ref.watch(authControllerProvider).valueOrNull?.permissions,
    );
    final canManage = CashierPermissions.canManageMenu(perms);

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر تحميل الأصناف',
          subtitle: _error,
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'إدارة الأصناف',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          if (!canManage) ...[
            const SizedBox(height: 8),
            const Text(
              'عرض فقط — تحتاج صلاحية menu.manage للتعديل.',
              style: TextStyle(fontSize: 12, color: HasimColors.muted),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () => _editCategory(),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text(
                      '+ إضافة تصنيف',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () => _editItem(),
                    icon: const Icon(Icons.add),
                    label: const Text(
                      '+ إضافة منتج',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: 'بحث…',
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: _load,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'التصنيفات',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (_categories.isEmpty)
            const HsEmpty(title: 'لا توجد تصنيفات.')
          else
            for (final c in _categories)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: HsCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${c['name']}${c['is_active'] == false ? ' (معطّل)' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (canManage) ...[
                        IconButton(
                          onPressed: () => _editCategory(existing: c),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                        IconButton(
                          onPressed: () => _deleteCategory(c),
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: HasimColors.danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 16),
          const Text('الأصناف', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_items.isEmpty)
            const HsEmpty(title: 'لا توجد أصناف.')
          else
            for (final item in _items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: HsCard(
                  padding: const EdgeInsets.all(12),
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
                              ),
                            ),
                            Text(
                              [
                                if (item['sku'] != null) 'SKU: ${item['sku']}',
                                if (item['barcode'] != null)
                                  'BC: ${item['barcode']}',
                                item['is_active'] == false ? 'معطّل' : 'نشط',
                              ].where((e) => e.isNotEmpty).join(' · '),
                              style: const TextStyle(
                                fontSize: 11,
                                color: HasimColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        ((item['price'] as num?) ?? 0).toStringAsFixed(2),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: HasimColors.ctaDark,
                        ),
                      ),
                      if (canManage) ...[
                        IconButton(
                          onPressed: () => _editItem(existing: item),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                        IconButton(
                          onPressed: () => _deleteItem(item),
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: HasimColors.danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _ItemFormDialog extends StatefulWidget {
  const _ItemFormDialog({required this.categories, this.existing});

  final List<Map<String, dynamic>> categories;
  final Map<String, dynamic>? existing;

  @override
  State<_ItemFormDialog> createState() => _ItemFormDialogState();
}

class _ItemFormDialogState extends State<_ItemFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _barcode;
  late final TextEditingController _type;
  late final TextEditingController _size;
  late final TextEditingController _desc;
  late final TextEditingController _price;
  late final TextEditingController _currency;
  int? _categoryId;
  var _active = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: '${e?['name'] ?? ''}');
    _sku = TextEditingController(text: '${e?['sku'] ?? ''}');
    _barcode = TextEditingController(text: '${e?['barcode'] ?? ''}');
    _type = TextEditingController(text: '${e?['item_type'] ?? 'عام'}');
    _size = TextEditingController(text: '${e?['size_label'] ?? ''}');
    _desc = TextEditingController(text: '${e?['description'] ?? ''}');
    _price = TextEditingController(
      text: ((e?['price'] as num?) ?? 0).toStringAsFixed(2),
    );
    _currency = TextEditingController(text: '${e?['currency'] ?? 'SAR'}');
    _categoryId =
        (e?['pos_item_category_id'] as num?)?.toInt() ??
        (e?['category'] is Map
            ? ((e!['category'] as Map)['id'] as num?)?.toInt()
            : null);
    _active = e?['is_active'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _barcode.dispose();
    _type.dispose();
    _size.dispose();
    _desc.dispose();
    _price.dispose();
    _currency.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'صنف جديد' : 'تعديل الصنف'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'الاسم'),
              ),
              TextField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'السعر'),
              ),
              TextField(
                controller: _currency,
                decoration: const InputDecoration(labelText: 'العملة'),
              ),
              DropdownButtonFormField<int?>(
                value: _categoryId,
                decoration: const InputDecoration(labelText: 'التصنيف'),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('— بدون —'),
                  ),
                  for (final c in widget.categories)
                    DropdownMenuItem<int?>(
                      value: (c['id'] as num).toInt(),
                      child: Text('${c['name']}'),
                    ),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
              TextField(
                controller: _sku,
                decoration: const InputDecoration(labelText: 'SKU'),
              ),
              TextField(
                controller: _barcode,
                decoration: const InputDecoration(labelText: 'Barcode'),
              ),
              TextField(
                controller: _type,
                decoration: const InputDecoration(labelText: 'النوع'),
              ),
              TextField(
                controller: _size,
                decoration: const InputDecoration(labelText: 'الحجم'),
              ),
              TextField(
                controller: _desc,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'الوصف'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('نشط / متاح'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            final price = double.tryParse(_price.text.trim());
            if (_name.text.trim().isEmpty || price == null || price < 0) {
              return;
            }
            Navigator.pop(context, {
              'name': _name.text.trim(),
              'sku': _sku.text.trim().isEmpty ? null : _sku.text.trim(),
              'barcode': _barcode.text.trim().isEmpty
                  ? null
                  : _barcode.text.trim(),
              'item_type': _type.text.trim().isEmpty
                  ? 'عام'
                  : _type.text.trim(),
              'pos_item_category_id': _categoryId,
              'size_label': _size.text.trim().isEmpty
                  ? null
                  : _size.text.trim(),
              'description': _desc.text.trim().isEmpty
                  ? null
                  : _desc.text.trim(),
              'price': price,
              'currency': _currency.text.trim().isEmpty
                  ? 'SAR'
                  : _currency.text.trim().toUpperCase(),
              'is_active': _active,
              'sort_order': widget.existing?['sort_order'] ?? 0,
            });
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
