import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/pos/application/pos_providers.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/theme/hasim_spacing.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Offline-only entry: local PIN or first-time standalone store setup.
/// No email / Google / Laravel login.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  var _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterLocal());
  }

  Future<void> _enterLocal() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = await ref.read(localAuthServiceProvider).anyStore();
      if (!mounted) return;
      if (store == null) {
        context.go('/standalone-setup');
      } else {
        context.go('/pin');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر فتح الوضع المحلي: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
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
                          'تشغيل محلي بدون إنترنت',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'لا يوجد اتصال بالخادم أو مزامنة. البيانات تُحفظ على هذا الجهاز فقط.',
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
                            onPressed: _loading ? null : _enterLocal,
                            icon: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.storefront_outlined),
                            label: Text(
                              _loading ? 'جاري الفتح…' : 'الدخول للكاشير المحلي',
                            ),
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
