import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Offline-only build never hits billing / Laravel — this screen is a dead end.
class PosBlockedScreen extends ConsumerWidget {
  const PosBlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [HasimColors.brandSoft, Colors.white],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(HasimRadius.lg),
                    border: Border.all(color: HasimColors.border),
                  ),
                  child: const Icon(Icons.lock_outline, color: HasimColors.muted),
                ),
                const SizedBox(height: 16),
                Text(
                  'الكاشير المحلي غير جاهز',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'أعد إعداد المتجر المحلي أو ادخل بـ PIN. التطبيق يعمل أوفلاين بدون خادم.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: HasimColors.muted),
                ),
                const SizedBox(height: 24),
                HsPrimaryButton(
                  label: 'العودة لتسجيل الدخول',
                  onPressed: () async {
                    await ref.read(authControllerProvider.notifier).logout();
                    if (context.mounted) context.go('/login');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> ensurePosEnabled(WidgetRef ref) async {
  // Offline-only: POS is always enabled for a local store session.
  return true;
}
