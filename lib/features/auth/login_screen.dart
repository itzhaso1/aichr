import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/pos_errors.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/theme/hasim_spacing.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Offline-only entry: email + password for cashier, chef, and admin.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _loading = true;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = await ref.read(localAuthServiceProvider).anyStore();
      if (!mounted) return;
      if (store == null) {
        context.go('/standalone-setup');
        return;
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر فتح الوضع المحلي: $e';
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).loginStandalonePin(
            username: _email.text.trim(),
            pin: _password.text,
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
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [HasimColors.brandSoft, Color(0xFFF8FAFC), Colors.white],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.all(HasimSpacing.xl),
                children: [
                  const SizedBox(height: 24),
                  Column(
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: HasimColors.surface,
                              borderRadius: BorderRadius.circular(
                                HasimRadius.lg,
                              ),
                              border: Border.all(color: HasimColors.border),
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'ح',
                              style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w900,
                                color: HasimColors.brand,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'حاسم',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              color: HasimColors.brand,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'كاشير حاسم — أوفلاين بالكامل',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      )
                      .animate()
                      .fadeIn(duration: 280.ms)
                      .slideY(begin: 0.06, end: 0),
                  const SizedBox(height: 28),
                  HsCard(
                    padding: const EdgeInsets.all(HasimSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'تسجيل الدخول',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'كل مستخدم يدخل بإيميله وكلمة المرور. بعد الدخول تُفتح الصفحات حسب صلاحياته.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        if (_error != null) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: HasimColors.dangerSoft,
                              borderRadius: BorderRadius.circular(
                                HasimRadius.sm,
                              ),
                              border: Border.all(
                                color: const Color(0xFFFECDD3),
                              ),
                            ),
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: HasimColors.danger,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (_loading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              ),
                            ),
                          )
                        else ...[
                          TextField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            decoration: const InputDecoration(
                              labelText: 'الإيميل',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _password,
                            obscureText: true,
                            onSubmitted: (_) => _busy ? null : _submit(),
                            decoration: const InputDecoration(
                              labelText: 'كلمة المرور',
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 48,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: HasimColors.brand,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    HasimRadius.md,
                                  ),
                                ),
                              ),
                              onPressed: _busy ? null : _submit,
                              icon: const Icon(Icons.login),
                              label: _busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('دخول'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
