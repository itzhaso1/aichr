import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/local_db/app_database.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/permissions/staff_permissions.dart';
import '../../core/pos/application/local_auth_service.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Admin directory of cashiers/chefs with per-user permission checkboxes.
class UsersAdminPanel extends ConsumerStatefulWidget {
  const UsersAdminPanel({super.key});

  @override
  ConsumerState<UsersAdminPanel> createState() => _UsersAdminPanelState();
}

class _UsersAdminPanelState extends ConsumerState<UsersAdminPanel> {
  List<LocalUser> _users = const [];
  var _loading = true;
  String? _error;
  String? _selectedId;
  Map<String, bool> _flags = {};
  var _saving = false;

  Map<String, dynamic> get _actorPerms => CashierPermissions.resolve(
        ref.read(cashierPermissionsProvider),
        ref.read(authControllerProvider).valueOrNull?.permissions,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  LocalUser? get _selected {
    for (final user in _users) {
      if (user.localId == _selectedId) return user;
    }
    return _users.isEmpty ? null : _users.first;
  }

  Future<void> _load() async {
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      setState(() {
        _loading = false;
        _error = 'لا توجد مساحة عمل محلية.';
        _users = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = ref.read(localAuthServiceProvider);
      final users = await auth.listUsers(workspaceId);
      LocalUser? selected;
      for (final user in users) {
        if (user.localId == _selectedId) {
          selected = user;
          break;
        }
      }
      selected ??= users.isEmpty ? null : users.first;
      Map<String, bool> flags = {};
      if (selected != null) {
        flags = await _flagsFor(selected);
      }
      if (!mounted) return;
      setState(() {
        _users = users;
        _selectedId = selected?.localId;
        _flags = flags;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<Map<String, bool>> _flagsFor(LocalUser user) async {
    final effective =
        await ref.read(localAuthServiceProvider).effectivePermissions(user);
    return {
      for (final item in StaffPermissions.catalog)
        item.key: StaffPermissions.can(effective, item.key),
    };
  }

  Future<void> _select(LocalUser user) async {
    final flags = await _flagsFor(user);
    if (!mounted) return;
    setState(() {
      _selectedId = user.localId;
      _flags = flags;
    });
  }

  Future<void> _saveAcl() async {
    final workspaceId = ref.read(workspaceIdProvider);
    final userId = _selectedId;
    if (workspaceId == null || userId == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(localAuthServiceProvider).writeUserAcl(
            workspaceId: workspaceId,
            userLocalId: userId,
            permissions: {
              for (final item in StaffPermissions.catalog)
                item.key: _flags[item.key] == true,
            },
            actorPermissions: _actorPerms,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ صلاحيات المستخدم.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PosException ? e.messageAr : '$e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createUser() async {
    if (!CashierPermissions.canManageUsers(_actorPerms)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية إنشاء الحسابات.')),
      );
      return;
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) return;
    final name = TextEditingController();
    final email = TextEditingController();
    final password = TextEditingController();
    var role = 'cashier';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('مستخدم جديد'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'الاسم'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'الإيميل'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور (4 أحرف على الأقل)',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: role,
                  decoration: const InputDecoration(labelText: 'الدور'),
                  items: const [
                    DropdownMenuItem(value: 'cashier', child: Text('كاشير')),
                    DropdownMenuItem(value: 'chef', child: Text('شيف')),
                    DropdownMenuItem(value: 'manager', child: Text('مشرف')),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => role = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إنشاء'),
            ),
          ],
        ),
      ),
    );
    final trimmedName = name.text.trim();
    final trimmedEmail = email.text.trim();
    final trimmedPassword = password.text.trim();
    name.dispose();
    email.dispose();
    password.dispose();
    if (ok != true) return;
    if (!mounted) return;
    if (trimmedName.isEmpty || trimmedEmail.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الاسم والإيميل مطلوبان.')),
      );
      return;
    }
    try {
      await ref.read(localAuthServiceProvider).createUser(
            workspaceId: workspaceId,
            name: trimmedName,
            username: trimmedEmail,
            pin: trimmedPassword,
            role: role,
            actorPermissions: _actorPerms,
          );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            role == 'chef'
                ? 'تم إنشاء حساب الشيف. يدخل بالإيميل وكلمة المرور إلى المطبخ.'
                : 'تم إنشاء الحساب. يدخل بالإيميل وكلمة المرور.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PosException ? e.messageAr : '$e')),
      );
    }
  }

  Future<void> _resetPassword(LocalUser user) async {
    if (!CashierPermissions.canManageUsers(_actorPerms)) {
      throw const Forbidden();
    }
    final password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('كلمة مرور جديدة — ${user.name}'),
        content: TextField(
          controller: password,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'كلمة المرور (4 أحرف على الأقل)',
          ),
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
    final trimmed = password.text.trim();
    password.dispose();
    if (ok != true || trimmed.isEmpty) return;
    try {
      await ref.read(localAuthServiceProvider).updateUserPassword(
            userLocalId: user.localId,
            pin: trimmed,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تحديث كلمة المرور.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PosException ? e.messageAr : '$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = CashierPermissions.canManageUsers(
      CashierPermissions.resolve(
        ref.watch(cashierPermissionsProvider),
        ref.watch(authControllerProvider).valueOrNull?.permissions,
      ),
    );
    if (!canManage) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: HsEmpty(
          title: 'غير مصرح بإدارة المستخدمين',
          subtitle: 'هذه الصفحة للمدير أو من مُنح صلاحية إدارة المستخدمين.',
        ),
      );
    }
    if (_loading && _users.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _users.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: HsEmpty(
          title: 'تعذر تحميل المستخدمين',
          subtitle: _error,
          actionLabel: 'إعادة المحاولة',
          onAction: _load,
        ),
      );
    }

    final selected = _selected;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 880;
        final list = _usersList(selected);
        final editor = selected == null
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: HsEmpty(title: 'اختر مستخدماً لعرض صلاحياته.'),
              )
            : _permissionEditor(selected);
        if (!wide) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _header(),
              const SizedBox(height: 12),
              list,
              const SizedBox(height: 12),
              SizedBox(height: 520, child: editor),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 320, child: list),
                    const SizedBox(width: 12),
                    Expanded(child: editor),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'المستخدمون والصلاحيات',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              SizedBox(height: 4),
              Text(
                'كل كاشير أو شيف له صلاحيات مستقلة. أعطِ أو أزل أي صلاحية ثم احفظ.',
                style: TextStyle(fontSize: 12, color: HasimColors.muted),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: _createUser,
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: const Text('مستخدم جديد'),
        ),
      ],
    );
  }

  Widget _usersList(LocalUser? selected) {
    return HsCard(
      child: _users.isEmpty
          ? const HsEmpty(title: 'لا يوجد مستخدمون بعد.')
          : ListView(
              shrinkWrap: true,
              children: [
                for (final user in _users)
                  ListTile(
                    selected: user.localId == selected?.localId,
                    title: Text(user.name),
                    subtitle: Text(
                      '${user.username} · ${LocalAuthService.roleLabelAr(user.role)}',
                    ),
                    trailing: HsBadge(
                      label: LocalAuthService.roleLabelAr(user.role),
                      background: LocalAuthService.isKitchenRole(user.role)
                          ? HasimColors.warningSoft
                          : HasimColors.navIdleBg,
                      foreground: HasimColors.ink,
                    ),
                    onTap: () => unawaited(_select(user)),
                  ),
              ],
            ),
    );
  }

  Widget _permissionEditor(LocalUser user) {
    final groups =
        <String, List<({String key, String labelAr, String group})>>{};
    for (final item in StaffPermissions.catalog) {
      groups.putIfAbsent(item.group, () => []).add(item);
    }
    return HsCard(
      child: ListView(
        children: [
          Text(
            user.name,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
          Text(
            '${user.username} · ${LocalAuthService.roleLabelAr(user.role)}',
            style: const TextStyle(fontSize: 12, color: HasimColors.muted),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: () => unawaited(_resetPassword(user)),
              child: const Text('تغيير كلمة المرور'),
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                entry.key,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            for (final item in entry.value)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _flags[item.key] == true,
                title: Text(item.labelAr, style: const TextStyle(fontSize: 13)),
                onChanged: (v) {
                  setState(() => _flags[item.key] = v == true);
                },
              ),
          ],
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _saving ? null : _saveAcl,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('حفظ الصلاحيات'),
          ),
        ],
      ),
    );
  }
}
