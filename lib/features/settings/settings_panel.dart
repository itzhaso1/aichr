import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api/cashier_api.dart';
import '../../core/audio/menu_sound_service.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/local_db/app_database.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/navigation/pos_shell_nav.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/pos/application/local_auth_service.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/domain/pricing_service.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/printing/printer_service.dart';
import '../../core/realtime/pos_event_source.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/theme/hasim_spacing.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';
import '../cart/cart_controller.dart';

/// Cashier settings — POS settings via API + local printer/realtime.
class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key});

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  var _sound = true;
  var _delivery = true;
  var _ready = false;
  var _savingPos = false;
  final _tax = TextEditingController(text: '0');
  final _currency = TextEditingController(text: 'SAR');
  PrinterProfile? _profile;
  final _name = TextEditingController(text: 'طابعة الشبكة');
  final _address = TextEditingController();
  PrinterTransport _transport = PrinterTransport.network;
  List<LocalUser> _users = const [];
  String? _storeName;
  LocalShift? _currentOpenShift;

  Map<String, dynamic> get _perms => CashierPermissions.resolve(
    ref.read(cashierPermissionsProvider),
    ref.read(authControllerProvider).valueOrNull?.permissions,
  );

  bool get _canManagePos => CashierPermissions.canManageMenu(_perms);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tax.dispose();
    _currency.dispose();
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sound = ref.read(menuSoundServiceProvider);
    final printer = await ref.read(printerServiceFutureProvider.future);
    Map<String, dynamic>? settings;
    final store = await ref.read(localAuthServiceProvider).anyStore();
    if (store != null) {
      settings = {'tax_rate': store.taxRate, 'currency': store.currency};
    }
    if (!mounted) return;
    setState(() {
      _storeName = store?.name;
      if (settings != null) {
        _tax.text = asDoubleOr(settings['tax_rate']).toStringAsFixed(2);
        _currency.text = '${settings['currency'] ?? 'SAR'}';
        _sound =
            settings['sound_enabled'] == true ||
            settings['new_order_sound'] == true;
        _delivery = settings['enable_delivery'] != false;
        ref.read(menuSoundServiceProvider).setEnabled(_sound);
        ref
            .read(cartControllerProvider.notifier)
            .setTaxRate(asDoubleOr(settings['tax_rate']));
      } else {
        _sound = sound.enabled;
      }
      _profile = printer.selected;
      if (_profile != null) {
        _name.text = _profile!.name;
        _address.text = _profile!.address ?? '';
        _transport = _profile!.transport;
      }
      _ready = true;
    });
    await _refreshUsers();
    await _refreshOpenShift();
  }

  Future<void> _refreshOpenShift() async {
    final workspaceId = ref.read(workspaceIdProvider);
    LocalShift? open;
    if (workspaceId != null) {
      try {
        open = await ref.read(shiftServiceProvider).currentOpen(workspaceId);
      } catch (_) {
        open = null;
      }
    }
    if (!mounted) return;
    setState(() => _currentOpenShift = open);
  }

  Future<void> _refreshUsers() async {
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) return;
    try {
      final users = await ref
          .read(localAuthServiceProvider)
          .listUsers(workspaceId);
      if (!mounted) return;
      setState(() => _users = users);
    } catch (_) {
      if (!mounted) return;
      setState(() => _users = const []);
    }
  }

  Future<void> _savePosSettings() async {
    if (!_canManagePos) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية تحديث إعدادات الكاشير.')),
      );
      return;
    }
    final tax = double.tryParse(_tax.text.trim());
    if (tax == null || tax < 0 || tax > 100) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('نسبة الضريبة غير صالحة.')));
      return;
    }
    setState(() => _savingPos = true);
    try {
      final store = await ref.read(localAuthServiceProvider).anyStore();
      if (store != null) {
        await ref
            .read(localAuthServiceProvider)
            .updateStore(
              storeId: store.localId,
              taxRate: tax,
              currency: _currency.text.trim().toUpperCase(),
            );
      }
      await ref.read(menuSoundServiceProvider).setEnabled(_sound);
      ref.read(cartControllerProvider.notifier).setTaxRate(tax);
      if (!mounted) return;
      setState(() => _savingPos = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ إعدادات المتجر محلياً.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingPos = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _savePrinter() async {
    final printer = await ref.read(printerServiceFutureProvider.future);
    final profile = PrinterProfile(
      id: _profile?.id ?? 'primary',
      name: _name.text.trim().isEmpty ? 'طابعة' : _name.text.trim(),
      transport: _transport,
      address: _address.text.trim().isEmpty ? null : _address.text.trim(),
    );
    await printer.saveProfile(profile);
    if (!mounted) return;
    setState(() => _profile = profile);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم حفظ إعدادات الطابعة.')));
  }

  Future<void> _testPrint() async {
    final printer = await ref.read(printerServiceFutureProvider.future);
    final result = await printer.testPrint();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _openShift() async {
    final workspaceId = ref.read(workspaceIdProvider);
    final userId = ref.read(currentLocalUserIdProvider) ?? 'local';
    if (workspaceId == null) return;
    final opening = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('افتتاح الكاش'),
        content: TextField(
          controller: opening,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'النقد الافتتاحي'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('افتتاح'),
          ),
        ],
      ),
    );
    final openingCash = double.tryParse(opening.text) ?? 0;
    opening.dispose();
    if (ok != true) return;
    try {
      final id = await ref
          .read(shiftServiceProvider)
          .open(
            workspaceId: workspaceId,
            userId: userId,
            openingCash: openingCash,
            permissions: ref
                .read(authControllerProvider)
                .valueOrNull
                ?.permissions,
          );
      ref.read(currentShiftIdProvider.notifier).state = id;
      await _refreshOpenShift();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم افتتاح الكاش.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PosException ? e.messageAr : '$e')),
      );
    }
  }

  Future<void> _closeShift() async {
    final workspaceId = ref.read(workspaceIdProvider);
    var shiftId = ref.read(currentShiftIdProvider);
    if (workspaceId == null) return;
    shiftId ??= (await ref.read(shiftServiceProvider).currentOpen(workspaceId))
        ?.localId;
    if (shiftId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا يوجد كاش مفتوح.')));
      return;
    }
    final actual = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إغلاق الكاش'),
        content: TextField(
          controller: actual,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'النقد الفعلي'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
    final actualCash = double.tryParse(actual.text) ?? 0;
    actual.dispose();
    if (ok != true) return;
    try {
      final result = await ref
          .read(shiftServiceProvider)
          .close(
            workspaceId: workspaceId,
            shiftId: shiftId,
            actualCash: actualCash,
            permissions: ref
                .read(authControllerProvider)
                .valueOrNull
                ?.permissions,
          );
      ref.read(currentShiftIdProvider.notifier).state = null;
      await _refreshOpenShift();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'المتوقع ${result['expected']} · الفعلي ${result['actual']} · الفرق ${result['difference']}',
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

  Future<void> _addLocalTable() async {
    if (!CashierPermissions.canCreateTables(_perms)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية إضافة طاولات.')),
      );
      return;
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا توجد مساحة عمل. أنشئ متجراً محلياً أولاً.'),
        ),
      );
      return;
    }
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('طاولة جديدة'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'اسم / رقم الطاولة'),
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
    final trimmed = name.text.trim();
    name.dispose();
    if (ok != true || trimmed.isEmpty) return;
    try {
      await ref
          .read(catalogAdminServiceProvider)
          .createTable(
            workspaceId: workspaceId,
            name: trimmed,
            permissions: CashierPermissions.resolve(
              ref.read(cashierPermissionsProvider),
              ref.read(authControllerProvider).valueOrNull?.permissions,
            ),
          );
      ref.invalidate(localTablesProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تمت إضافة الطاولة. افتح تبويب الطاولات لعرضها.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final message = e is PosException ? e.messageAr : '$e';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر إضافة الطاولة: $message')));
    }
  }

  Future<String?> _askBackupPassword({required String title}) async {
    final password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'كلمة مرور النسخة (6 أحرف على الأقل)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
    final value = password.text;
    password.dispose();
    if (ok != true) return null;
    return value;
  }

  Future<void> _exportBackup() async {
    if (!CashierPermissions.canBackup(_perms)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية النسخ الاحتياطي.')),
      );
      return;
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null) return;
    final password = await _askBackupPassword(title: 'تشفير النسخة الاحتياطية');
    if (password == null) return;
    try {
      final file = await ref
          .read(backupServiceProvider)
          .exportBackup(
            workspaceId: workspaceId,
            password: password,
            permissions: _perms,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تم التصدير: ${file.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _restoreBackup() async {
    if (!CashierPermissions.canBackup(_perms)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية استعادة النسخة.')),
      );
      return;
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null) return;
    final backups = await ref.read(backupServiceProvider).listBackups();
    if (backups.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد نسخة احتياطية بعد. صدّر أولاً.')),
      );
      return;
    }
    final chosen = backups.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('استعادة النسخة؟'),
        content: Text(
          'سيتم أخذ نسخة أمان ثم الكتابة فوق البيانات من:\n${chosen.path}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('استعادة'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final password = await _askBackupPassword(title: 'كلمة مرور النسخة');
    if (password == null) return;
    try {
      await ref
          .read(backupServiceProvider)
          .exportBackup(
            workspaceId: workspaceId,
            password: password,
            permissions: _perms,
          );
      await ref
          .read(backupServiceProvider)
          .restoreFile(
            chosen,
            confirmed: true,
            password: password,
            permissions: _perms,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تمت الاستعادة.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PosException ? e.messageAr : '$e')),
      );
    }
  }

  Future<void> _createStaffUser() async {
    if (!CashierPermissions.canManageUsers(_perms)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا تملك صلاحية إنشاء الحسابات.')),
      );
      return;
    }
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null || workspaceId <= 0) return;
    final name = TextEditingController();
    final username = TextEditingController();
    final pin = TextEditingController();
    var role = 'cashier';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('حساب جديد'),
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
                  controller: username,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'الإيميل'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pin,
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
    final trimmedUser = username.text.trim();
    final trimmedPin = pin.text.trim();
    name.dispose();
    username.dispose();
    pin.dispose();
    if (ok != true) return;
    if (!mounted) return;
    if (trimmedName.isEmpty || trimmedUser.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('الاسم والإيميل مطلوبان.')));
      return;
    }
    try {
      await ref
          .read(localAuthServiceProvider)
          .createUser(
            workspaceId: workspaceId,
            name: trimmedName,
            username: trimmedUser,
            pin: trimmedPin,
            role: role == 'chef' ? 'chef' : 'cashier',
            actorPermissions: _perms,
          );
      await _refreshUsers();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            role == 'chef'
                ? 'تم إنشاء حساب الشيف. يدخل بالإيميل وكلمة المرور إلى المطبخ.'
                : 'تم إنشاء حساب الكاشير.',
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

  String _formatOpenedAt(DateTime at) {
    return DateFormat('yyyy/MM/dd  HH:mm').format(at.toLocal());
  }

  ({Color background, Color foreground}) _roleTone(String role) {
    if (LocalAuthService.isKitchenRole(role)) {
      return (
        background: HasimColors.warningSoft,
        foreground: HasimColors.warning,
      );
    }
    final value = role.trim().toLowerCase();
    if (value == 'admin' || value == 'manager') {
      return (
        background: HasimColors.brandSoft,
        foreground: HasimColors.brandDark,
      );
    }
    return (background: HasimColors.ctaSoft, foreground: HasimColors.ctaDark);
  }

  Widget _infoBanner({
    required IconData icon,
    required String text,
    Color background = HasimColors.brandSoft,
    Color foreground = HasimColors.brandDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(HasimRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCard() {
    return HsCard(
      color: HasimColors.ctaDark,
      borderColor: HasimColors.ctaDark,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.settings_outlined,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'لوحة التحكم',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'إدارة النظام والتفضيلات العامة',
                  style: TextStyle(fontSize: 12, color: Color(0xD9FFFFFF)),
                ),
              ],
            ),
          ),
          if (_storeName != null && _storeName!.trim().isNotEmpty)
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.storefront_outlined,
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _storeName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'نقطة بيع محلية',
                    style: TextStyle(fontSize: 11, color: Color(0xD9FFFFFF)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _usersCard() {
    return HsSectionCard(
      icon: Icons.groups_outlined,
      iconBackground: HasimColors.brandSoft,
      iconColor: HasimColors.brandDark,
      title: 'حسابات الكاشير والشيف',
      subtitle:
          'كل مستخدم يدخل بإيميل وكلمة مرور. الصلاحيات تُحدد لكل شخص بشكل مستقل من تبويب المستخدمون.',
      children: [
        if (_users.isEmpty)
          const Text(
            'لا يوجد مستخدمون بعد.',
            style: TextStyle(fontSize: 12, color: HasimColors.muted),
          )
        else
          for (final user in _users)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          user.username,
                          style: const TextStyle(
                            fontSize: 12,
                            color: HasimColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  HsBadge(
                    label: LocalAuthService.roleLabelAr(user.role),
                    background: _roleTone(user.role).background,
                    foreground: _roleTone(user.role).foreground,
                  ),
                ],
              ),
            ),
        HsOutlineButton(
          label: 'إدارة المستخدمين والصلاحيات',
          icon: Icons.manage_accounts_outlined,
          onPressed: () => requestPosShellTab(ref, PosShellTab.users),
        ),
        HsPrimaryButton(
          label: 'إنشاء حساب كاشير أو شيف',
          icon: Icons.person_add_alt_1_outlined,
          onPressed: _createStaffUser,
        ),
      ],
    );
  }

  Widget _cashCard() {
    final open = _currentOpenShift;
    final currency = _currency.text.trim().isEmpty
        ? 'SAR'
        : _currency.text.trim();
    return HsSectionCard(
      icon: Icons.point_of_sale_outlined,
      iconBackground: HasimColors.ctaSoft,
      iconColor: HasimColors.ctaDark,
      title: 'افتتاح الكاش',
      subtitle: 'يجب افتتاح الكاش قبل بدء البيع.',
      highlight: true,
      children: [
        if (open != null) ...[
          _infoBanner(
            icon: Icons.check_circle_outline,
            text:
                'الكاش مفتوح · وقت الافتتاح ${_formatOpenedAt(open.openedAt)}'
                ' · نقد الافتتاح ${Money.fromCents(open.openingCash).toStringAsFixed(2)} $currency',
            background: Colors.white,
            foreground: HasimColors.ctaDark,
          ),
        ] else
          _infoBanner(
            icon: Icons.info_outline,
            text: 'افتتاح الكاش مطلوب قبل بدء البيع على هذا الجهاز.',
            background: Colors.white,
            foreground: HasimColors.brandDark,
          ),
        HsPrimaryButton(
          label: 'افتتاح الكاش',
          icon: Icons.lock_open_outlined,
          onPressed: _openShift,
        ),
        HsOutlineButton(
          label: 'إغلاق الكاش',
          icon: Icons.lock_outline,
          onPressed: _closeShift,
        ),
      ],
    );
  }

  Widget _posSettingsCard({required bool canManage}) {
    return HsSectionCard(
      icon: Icons.tune,
      iconBackground: HasimColors.warningSoft,
      iconColor: HasimColors.warning,
      title: 'إعدادات الكاشير المحلية',
      subtitle: canManage
          ? 'تُحفظ محلياً على هذا الجهاز (بدون خادم)'
          : 'عرض فقط — تحتاج menu.manage للتعديل',
      children: [
        TextField(
          controller: _tax,
          enabled: canManage && _ready && !_savingPos,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'نسبة الضريبة %',
            isDense: true,
          ),
        ),
        TextField(
          controller: _currency,
          enabled: canManage && _ready && !_savingPos,
          decoration: const InputDecoration(labelText: 'العملة', isDense: true),
        ),
        HsToggleRow(
          label: 'صوت طلبات المنيو',
          value: _sound,
          onChanged: (!canManage || !_ready || _savingPos)
              ? null
              : (v) => setState(() => _sound = v),
        ),
        HsToggleRow(
          label: 'تفعيل التوصيل',
          value: _delivery,
          onChanged: (!canManage || !_ready || _savingPos)
              ? null
              : (v) => setState(() => _delivery = v),
        ),
        if (canManage)
          HsPrimaryButton(
            label: _savingPos ? 'جاري الحفظ…' : 'حفظ إعدادات الكاشير',
            icon: Icons.save_outlined,
            onPressed: (!_ready || _savingPos) ? null : _savePosSettings,
          ),
      ],
    );
  }

  Widget _stationsCard({
    required bool canViewReports,
    required bool canUseKitchen,
  }) {
    return HsSectionCard(
      icon: Icons.assessment_outlined,
      iconBackground: HasimColors.brandSoft,
      iconColor: HasimColors.brandDark,
      title: 'التقارير والمطبخ',
      subtitle:
          'التقارير والمطبخ صفحتان مستقلتان. صلاحية الدخول تُحدد لكل مستخدم من تبويب المستخدمون.',
      children: [
        if (canViewReports)
          HsOutlineButton(
            label: 'فتح التقارير',
            icon: Icons.bar_chart_outlined,
            onPressed: () {
              final router = GoRouter.maybeOf(context);
              if (router != null) {
                context.go('/reports');
              } else {
                requestPosShellTab(ref, PosShellTab.reports);
              }
            },
          ),
        if (canUseKitchen)
          HsOutlineButton(
            label: 'فتح المطبخ',
            icon: Icons.soup_kitchen_outlined,
            onPressed: () {
              final router = GoRouter.maybeOf(context);
              if (router != null) {
                context.go('/kitchen');
              } else {
                requestPosShellTab(ref, PosShellTab.kitchen);
              }
            },
          ),
      ],
    );
  }

  Widget _backupCard() {
    return HsSectionCard(
      icon: Icons.sd_storage_outlined,
      iconBackground: HasimColors.ctaSoft,
      iconColor: HasimColors.ctaDark,
      title: 'نسخة احتياطية محلية',
      subtitle: 'تصدير واستعادة بيانات هذا الجهاز.',
      children: [
        HsPrimaryButton(
          label: 'تصدير Backup',
          icon: Icons.file_upload_outlined,
          onPressed: _exportBackup,
        ),
        HsOutlineButton(
          label: 'استعادة آخر نسخة',
          icon: Icons.file_download_outlined,
          onPressed: _restoreBackup,
        ),
      ],
    );
  }

  Widget _tablesCard() {
    return HsSectionCard(
      icon: Icons.table_restaurant_outlined,
      iconBackground: HasimColors.ctaSoft,
      iconColor: HasimColors.ctaDark,
      title: 'الطاولات',
      subtitle: 'إضافة طاولة محلية لهذا الجهاز.',
      children: [
        HsOutlineButton(
          label: 'إضافة طاولة محلية',
          icon: Icons.add,
          onPressed: _addLocalTable,
        ),
      ],
    );
  }

  Widget _soundCard() {
    return HsSectionCard(
      icon: Icons.volume_up_outlined,
      iconBackground: HasimColors.warningSoft,
      iconColor: HasimColors.warning,
      title: 'اختبار الصوت',
      subtitle: 'تشغيل عينة صوت طلب جديد.',
      children: [
        HsOutlineButton(
          label: 'تشغيل عينة',
          icon: Icons.play_arrow_rounded,
          onPressed: () => ref.read(menuSoundServiceProvider).playNewOrder(),
        ),
      ],
    );
  }

  Widget _realtimeCard() {
    return HsSectionCard(
      icon: Icons.wifi_tethering,
      iconBackground: HasimColors.brandSoft,
      iconColor: HasimColors.brandDark,
      title: 'Realtime',
      subtitle:
          'Polling هو المصدر الافتراضي. Pusher/Reverb لن يُفعَّل بدون credentials.',
      children: [
        Text(
          'الوضع الحالي: ${ref.watch(posRealtimeModeProvider)}',
          style: const TextStyle(fontSize: 12, color: HasimColors.muted),
        ),
      ],
    );
  }

  Widget _printerCard() {
    return HsSectionCard(
      icon: Icons.print_outlined,
      iconBackground: HasimColors.ctaSoft,
      iconColor: HasimColors.ctaDark,
      title: 'إعدادات الطابعة (ESC/POS)',
      subtitle: _profile == null
          ? 'غير مُعدّة'
          : (_profile!.address == null || _profile!.address!.isEmpty
                ? 'محفوظة بدون عنوان (غير متصلة)'
                : 'عنوان محفوظ — الإرسال يحتاج بوابة Native حقيقية'),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'اسم الطابعة',
            isDense: true,
          ),
        ),
        DropdownButtonFormField<PrinterTransport>(
          value: _transport,
          decoration: const InputDecoration(
            labelText: 'نوع الاتصال',
            isDense: true,
          ),
          items: const [
            DropdownMenuItem(
              value: PrinterTransport.network,
              child: Text('Network'),
            ),
            DropdownMenuItem(
              value: PrinterTransport.bluetooth,
              child: Text('Bluetooth'),
            ),
            DropdownMenuItem(value: PrinterTransport.usb, child: Text('USB')),
            DropdownMenuItem(
              value: PrinterTransport.system,
              child: Text('System'),
            ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _transport = v);
          },
        ),
        TextField(
          controller: _address,
          decoration: const InputDecoration(
            labelText: 'العنوان (IP / MAC / USB path)',
            isDense: true,
            hintText: 'مثال: 192.168.1.50',
          ),
        ),
        Row(
          children: [
            Expanded(
              child: HsPrimaryButton(
                label: 'حفظ الطابعة',
                onPressed: _savePrinter,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HsOutlineButton(
                label: 'Test Print',
                onPressed: _testPrint,
              ),
            ),
          ],
        ),
        const Text(
          'طابعة الشبكة ترسل ESC/POS عبر TCP:9100. Bluetooth/USB يحتاج Native لاحقاً. فشل الطباعة لا يلغي البيع.',
          style: TextStyle(fontSize: 11, color: HasimColors.muted),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canManage = CashierPermissions.canManageMenu(
      CashierPermissions.resolve(
        ref.watch(cashierPermissionsProvider),
        ref.watch(authControllerProvider).valueOrNull?.permissions,
      ),
    );
    final canManageUsers = CashierPermissions.canManageUsers(
      CashierPermissions.resolve(
        ref.watch(cashierPermissionsProvider),
        ref.watch(authControllerProvider).valueOrNull?.permissions,
      ),
    );
    final canCreateTables = CashierPermissions.canCreateTables(
      CashierPermissions.resolve(
        ref.watch(cashierPermissionsProvider),
        ref.watch(authControllerProvider).valueOrNull?.permissions,
      ),
    );
    final canViewReports = CashierPermissions.canViewReports(
      CashierPermissions.resolve(
        ref.watch(cashierPermissionsProvider),
        ref.watch(authControllerProvider).valueOrNull?.permissions,
      ),
    );
    final canUseKitchen = CashierPermissions.canUseKitchen(
      CashierPermissions.resolve(
        ref.watch(cashierPermissionsProvider),
        ref.watch(authControllerProvider).valueOrNull?.permissions,
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(HasimSpacing.lg),
      children: [
        _headerCard(),
        const SizedBox(height: HasimSpacing.md),
        HsSoftGrid(
          minTileWidth: 300,
          maxColumns: 3,
          children: [
            if (canManageUsers) _usersCard(),
            _cashCard(),
            _posSettingsCard(canManage: canManage),
            if (canViewReports || canUseKitchen)
              _stationsCard(
                canViewReports: canViewReports,
                canUseKitchen: canUseKitchen,
              ),
            _backupCard(),
            _soundCard(),
            if (canCreateTables) _tablesCard(),
            _realtimeCard(),
            _printerCard(),
          ],
        ),
      ],
    );
  }
}
