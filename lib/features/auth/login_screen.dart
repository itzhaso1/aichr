import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/theme/hasim_spacing.dart';
import '../../core/widgets/hasim_widgets.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  var _obscure = true;
  var _loading = false;
  var _googleBusy = false;
  String? _error;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(_identifier.text.trim(), _password.text);
    } catch (e) {
      setState(() {
        _error = e is ApiException ? e.message : 'تعذر تسجيل الدخول.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enterLocal() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = await ref.read(localAuthServiceProvider).anyStore();
      if (!mounted) return;
      if (store == null) {
        context.push('/standalone-setup');
      } else {
        context.push('/pin');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر فتح الوضع المحلي: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _google() async {
    setState(() {
      _googleBusy = true;
      _error = null;
    });
    try {
      final google = GoogleSignIn(scopes: const ['email', 'profile']);
      final account = await google.signIn();
      if (account == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم إلغاء تسجيل الدخول عبر Google.')),
          );
        }
        return;
      }
      final auth = await account.authentication;
      final token = auth.accessToken ?? auth.idToken;
      if (token == null || token.isEmpty) {
        if (mounted) {
          setState(() => _error = 'يحتاج إعداد Google على هذا الجهاز.');
        }
        return;
      }
      await ref
          .read(authControllerProvider.notifier)
          .socialLogin(provider: 'google', accessToken: token);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      final needsSetup =
          msg.contains('client') ||
          msg.contains('platform') ||
          msg.contains('missing') ||
          msg.contains('not been configured') ||
          msg.contains('sign_in_failed') ||
          msg.contains('10:') ||
          msg.contains('12500');
      setState(() {
        _error = e is ApiException
            ? e.message
            : (needsSetup
                  ? 'يحتاج إعداد Google على هذا الجهاز.'
                  : 'تعذر تسجيل الدخول عبر Google.');
      });
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _loading || _googleBusy;
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
              constraints: const BoxConstraints(maxWidth: 440),
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
                            'كاشير حاسم',
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
                          'مرحبًا بك في حاسم',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'سجّل الدخول بنفس حساب مساحة العمل',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _identifier,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'البريد الإلكتروني أو الجوال',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          obscureText: _obscure,
                          enabled: !busy,
                          onSubmitted: (_) => busy ? null : _submit(),
                          decoration: InputDecoration(
                            labelText: 'كلمة المرور',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            onPressed: busy
                                ? null
                                : () => context.push('/forgot-password'),
                            child: const Text('نسيت كلمة المرور؟'),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 4),
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
                          const SizedBox(height: 8),
                        ],
                        SizedBox(
                          height: 48,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: HasimColors.brand,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  HasimRadius.md,
                                ),
                              ),
                            ),
                            onPressed: busy ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('تسجيل الدخول'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: busy ? null : _enterLocal,
                            icon: const Icon(Icons.storefront_outlined),
                            label: const Text('كاشير محلي مستقل'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'يعمل بدون إنترنت وبدون Laravel. أنشئ متجراً محلياً أو ادخل بـ PIN.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: Text(
                                'أو',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: busy ? null : _google,
                            icon: _googleBusy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.g_mobiledata_rounded,
                                    size: 28,
                                  ),
                            label: const Text('الدخول عبر Google'),
                          ),
                        ),
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
