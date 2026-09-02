import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/audio/menu_sound_service.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/permissions/permissions_provider.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/printing/printer_service.dart';
import '../../core/realtime/pos_event_source.dart';
import '../../core/theme/hasim_colors.dart';
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
      settings = {
        'tax_rate': store.taxRate,
        'currency': store.currency,
      };
    }
    if (!mounted) return;
    setState(() {
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
        title: const Text('فتح وردية'),
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
            child: const Text('فتح'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final id = await ref
          .read(shiftServiceProvider)
          .open(
            workspaceId: workspaceId,
            userId: userId,
            openingCash: double.tryParse(opening.text) ?? 0,
            permissions: ref.read(authControllerProvider).valueOrNull?.permissions,
          );
      ref.read(currentShiftIdProvider.notifier).state = id;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم فتح الوردية.')));
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
      ).showSnackBar(const SnackBar(content: Text('لا توجد وردية مفتوحة.')));
      return;
    }
    final actual = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إغلاق الوردية'),
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
    if (ok != true) return;
    try {
      final result = await ref
          .read(shiftServiceProvider)
          .close(
            workspaceId: workspaceId,
            shiftId: shiftId,
            actualCash: double.tryParse(actual.text) ?? 0,
            permissions: ref.read(authControllerProvider).valueOrNull?.permissions,
          );
      ref.read(currentShiftIdProvider.notifier).state = null;
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
    final workspaceId = ref.read(workspaceIdProvider);
    if (workspaceId == null) return;
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('طاولة جديدة'),
        content: TextField(
          controller: name,
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
    if (ok != true || name.text.trim().isEmpty) return;
    await ref
        .read(catalogAdminServiceProvider)
        .createTable(
          workspaceId: workspaceId,
          name: name.text.trim(),
          permissions: ref.read(authControllerProvider).valueOrNull?.permissions,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تمت إضافة الطاولة محلياً.')));
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
      await ref.read(backupServiceProvider).exportBackup(
            workspaceId: workspaceId,
            password: password,
            permissions: _perms,
          );
      await ref.read(backupServiceProvider).restoreFile(
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

  @override
  Widget build(BuildContext context) {
    final canManage = CashierPermissions.canManageMenu(
      CashierPermissions.resolve(
        ref.watch(cashierPermissionsProvider),
        ref.watch(authControllerProvider).valueOrNull?.permissions,
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'الإعدادات',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 12),
        HsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'الوردية والصندوق',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              HsPrimaryButton(label: 'فتح وردية', onPressed: _openShift),
              const SizedBox(height: 8),
              HsOutlineButton(label: 'إغلاق الوردية', onPressed: _closeShift),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'نسخة احتياطية محلية',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              HsPrimaryButton(label: 'تصدير Backup', onPressed: _exportBackup),
              const SizedBox(height: 8),
              HsOutlineButton(
                label: 'استعادة آخر نسخة',
                onPressed: _restoreBackup,
              ),
              const SizedBox(height: 8),
              HsOutlineButton(
                label: 'إضافة طاولة محلية',
                onPressed: _addLocalTable,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'إعدادات الكاشير المحلية',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                canManage
                    ? 'تُحفظ محلياً على هذا الجهاز (بدون خادم)'
                    : 'عرض فقط — تحتاج menu.manage للتعديل',
                style: const TextStyle(fontSize: 12, color: HasimColors.muted),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _tax,
                enabled: canManage && _ready && !_savingPos,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'نسبة الضريبة %',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _currency,
                enabled: canManage && _ready && !_savingPos,
                decoration: const InputDecoration(
                  labelText: 'العملة',
                  isDense: true,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'صوت طلبات المنيو',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                value: _sound,
                activeThumbColor: HasimColors.cta,
                onChanged: (!canManage || !_ready || _savingPos)
                    ? null
                    : (v) => setState(() => _sound = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'تفعيل التوصيل',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                value: _delivery,
                activeThumbColor: HasimColors.cta,
                onChanged: (!canManage || !_ready || _savingPos)
                    ? null
                    : (v) => setState(() => _delivery = v),
              ),
              if (canManage)
                HsPrimaryButton(
                  label: _savingPos ? 'جاري الحفظ…' : 'حفظ إعدادات الكاشير',
                  onPressed: (!_ready || _savingPos) ? null : _savePosSettings,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'اختبار الصوت',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              HsOutlineButton(
                label: 'تشغيل عينة',
                onPressed: () =>
                    ref.read(menuSoundServiceProvider).playNewOrder(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Realtime',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'الوضع الحالي: ${ref.watch(posRealtimeModeProvider)}',
                style: const TextStyle(fontSize: 12, color: HasimColors.muted),
              ),
              const SizedBox(height: 4),
              const Text(
                'Polling هو المصدر الافتراضي. Pusher/Reverb لن يُفعَّل بدون credentials.',
                style: TextStyle(fontSize: 12, color: HasimColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'إعدادات الطابعة (ESC/POS)',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'الحالة: ${_profile == null ? 'غير مُعدّة' : (_profile!.address == null || _profile!.address!.isEmpty ? 'محفوظة بدون عنوان (غير متصلة)' : 'عنوان محفوظ — الإرسال يحتاج بوابة Native حقيقية')}',
                style: const TextStyle(fontSize: 12, color: HasimColors.muted),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'اسم الطابعة',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
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
                  DropdownMenuItem(
                    value: PrinterTransport.usb,
                    child: Text('USB'),
                  ),
                  DropdownMenuItem(
                    value: PrinterTransport.system,
                    child: Text('System'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _transport = v);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: 'العنوان (IP / MAC / USB path)',
                  isDense: true,
                  hintText: 'مثال: 192.168.1.50',
                ),
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 8),
              const Text(
                'طابعة الشبكة ترسل ESC/POS عبر TCP:9100. Bluetooth/USB يحتاج Native لاحقاً. فشل الطباعة لا يلغي البيع.',
                style: TextStyle(fontSize: 11, color: HasimColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
