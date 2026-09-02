import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/theme/hasim_spacing.dart';
import '../../core/widgets/hasim_widgets.dart';

class StandaloneSetupScreen extends ConsumerStatefulWidget {
  const StandaloneSetupScreen({super.key});

  @override
  ConsumerState<StandaloneSetupScreen> createState() =>
      _StandaloneSetupScreenState();
}

class _StandaloneSetupScreenState extends ConsumerState<StandaloneSetupScreen> {
  final _store = TextEditingController(text: 'متجري');
  final _admin = TextEditingController(text: 'المدير');
  final _username = TextEditingController(text: 'admin');
  final _pin = TextEditingController();
  final _tax = TextEditingController(text: '15');
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _store.dispose();
    _admin.dispose();
    _username.dispose();
    _pin.dispose();
    _tax.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .bootstrapStandaloneStore(
            storeName: _store.text.trim(),
            adminName: _admin.text.trim(),
            username: _username.text.trim(),
            pin: _pin.text,
            taxRate: double.tryParse(_tax.text.trim()) ?? 0,
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is PosException ? e.messageAr : e.toString();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إعداد المتجر المحلي')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListView(
            padding: const EdgeInsets.all(HasimSpacing.xl),
            children: [
              const Text(
                'يعمل الكاشير بالكامل بدون إنترنت وبدون Laravel.',
                style: TextStyle(color: HasimColors.muted),
              ),
              const SizedBox(height: 16),
              HsCard(
                padding: const EdgeInsets.all(HasimSpacing.lg),
                child: Column(
                  children: [
                    TextField(
                      controller: _store,
                      decoration: const InputDecoration(
                        labelText: 'اسم المتجر',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _admin,
                      decoration: const InputDecoration(
                        labelText: 'اسم المدير',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'PIN (4 أرقام على الأقل)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tax,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'نسبة الضريبة %',
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(color: HasimColors.danger),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 48,
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: HasimColors.brand,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(HasimRadius.md),
                          ),
                        ),
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : const Text('إنشاء المتجر والدخول'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
