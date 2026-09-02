import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/pos/pos_mode.dart';
import '../../core/sync/pos_sync_coordinator.dart';
import '../../core/theme/hasim_colors.dart';

class CustomersPanel extends ConsumerStatefulWidget {
  const CustomersPanel({super.key});

  @override
  ConsumerState<CustomersPanel> createState() => _CustomersPanelState();
}

class _CustomersPanelState extends ConsumerState<CustomersPanel> {
  List<Map<String, dynamic>> _customers = const [];
  var _loading = true;
  String? _error;
  final _search = TextEditingController();

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
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      setState(() {
        _loading = false;
        _error = 'لا توجد مساحة عمل';
      });
      return;
    }
    try {
      final local = await ref.read(customersRepositoryProvider).list(
            workspaceId: workspaceId,
            query: _search.text,
          );
      if (local.isNotEmpty) {
        setState(() {
          _customers = local;
          _loading = false;
        });
      }
      final session = ref.read(authControllerProvider).valueOrNull;
      if (PosMode.isStandaloneRuntime(
        isLocalMode: session?.isLocalMode == true,
        token: session?.token,
      )) {
        if (!mounted) return;
        setState(() {
          _customers = local;
          _loading = false;
        });
        return;
      }
      // Best-effort remote refresh into local store for next time.
      try {
        final data = await ref.read(cashierApiProvider).get(
          '/customers',
          query: {
            if (_search.text.trim().isNotEmpty) 'q': _search.text.trim(),
          },
        );
        final list = <Map<String, dynamic>>[];
        final raw = data['customers'] ?? data['value'];
        if (raw is List) {
          for (final item in raw) {
            if (item is Map) list.add(Map<String, dynamic>.from(item));
          }
        }
        if (list.isNotEmpty) {
          await ref.read(customersRepositoryProvider).upsertRemoteSnapshot(
                workspaceId: workspaceId,
                customers: list,
              );
        }
        final refreshed = await ref.read(customersRepositoryProvider).list(
              workspaceId: workspaceId,
              query: _search.text,
            );
        if (mounted) {
          setState(() {
            _customers = refreshed.isNotEmpty ? refreshed : list;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _customers = local;
            _loading = false;
            if (local.isEmpty) {
              _error = 'تعذر تحميل العملاء';
            }
          });
        }
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _addCustomer() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة عميل'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'الاسم'),
            ),
            TextField(
              controller: phone,
              decoration: const InputDecoration(labelText: 'الجوال'),
              keyboardType: TextInputType.phone,
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
    if (ok != true || name.text.trim().isEmpty) return;
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null) return;
    try {
      final deviceId =
          await ref.read(deviceIdentityProvider).getOrCreateDeviceId();
      await ref.read(customersRepositoryProvider).createOffline(
            workspaceId: workspaceId,
            deviceId: deviceId,
            name: name.text.trim(),
            phone: phone.text.trim().isEmpty ? '0000000000' : phone.text.trim(),
            clientReference: const Uuid().v4(),
          );
      await ref.read(posSyncCoordinatorProvider).flushPendingOrders(
            workspaceId: workspaceId,
            deviceId: deviceId,
          );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: 'بحث بالاسم أو الجوال',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onSubmitted: (_) => _load(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _addCustomer,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('إضافة'),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: const TextStyle(color: HasimColors.danger)),
          ),
        Expanded(
          child: _customers.isEmpty && !_loading
              ? const Center(child: Text('لا يوجد عملاء'))
              : ListView.separated(
                  itemCount: _customers.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = _customers[i];
                    final pending = c['is_local_pending'] == true ||
                        c['sync_status'] == 'pending';
                    return ListTile(
                      title: Text('${c['name'] ?? ''}'),
                      subtitle: Text('${c['phone'] ?? ''}'),
                      trailing: pending
                          ? const Chip(label: Text('بانتظار المزامنة'))
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
