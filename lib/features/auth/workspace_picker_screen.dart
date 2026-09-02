import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';

class WorkspacePickerScreen extends ConsumerStatefulWidget {
  const WorkspacePickerScreen({super.key});

  @override
  ConsumerState<WorkspacePickerScreen> createState() =>
      _WorkspacePickerScreenState();
}

class _WorkspacePickerScreenState extends ConsumerState<WorkspacePickerScreen> {
  List<Map<String, dynamic>> _items = const [];
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      if (session != null && session.workspaces.isNotEmpty) {
        setState(() {
          _items = session.workspaces;
          _loading = false;
        });
        return;
      }
      final data = await ref.read(cashierApiProvider).get('/workspaces');
      final list = <Map<String, dynamic>>[];
      final raw = data['workspaces'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            if (map['workspace'] is Map) {
              final ws = Map<String, dynamic>.from(map['workspace'] as Map);
              list.add({
                ...ws,
                'pos_enabled': map['pos_enabled'] == true,
              });
            } else {
              list.add(map);
            }
          }
        }
      }
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e is ApiException ? e.message : 'تعذر تحميل مساحات العمل.';
        _loading = false;
      });
    }
  }

  Future<void> _select(Map<String, dynamic> workspace) async {
    await ref.read(authControllerProvider.notifier).selectWorkspace(workspace);
    if (!mounted) return;
    final session = ref.read(authControllerProvider).valueOrNull;
    if (session != null && session.permissions.isNotEmpty) {
      ref.read(cashierPermissionsProvider.notifier).state =
          Map<String, dynamic>.from(session.permissions);
    }
    final posEnabled = session?.posEnabled ?? (workspace['pos_enabled'] != false);
    if (!posEnabled) {
      context.go('/pos-blocked');
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HasimColors.page,
      appBar: AppBar(title: const Text('اختر مساحة العمل')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: HsEmpty(title: _error!))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _items.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final ws = _items[index];
                    final posEnabled = ws['pos_enabled'] != false;
                    return Material(
                      color: HasimColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _select(ws),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: HasimColors.border),
                          ),
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      (ws['name'] as String?) ?? 'Workspace',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      posEnabled
                                          ? 'الكاشير متاح'
                                          : 'الكاشير غير متاح في الباقة',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: posEnabled
                                            ? HasimColors.ctaDark
                                            : HasimColors.muted,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_left),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
