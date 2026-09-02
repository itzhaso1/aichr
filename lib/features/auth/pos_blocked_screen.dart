import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/theme/hasim_radius.dart';
import '../../core/widgets/hasim_widgets.dart';

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
                  'الكاشير غير متاح في باقتك الحالية',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'قم بترقية الباقة لتفعيل ميزة الكاشير في مساحة العمل الحالية.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: HasimColors.muted),
                ),
                const SizedBox(height: 24),
                HsPrimaryButton(
                  label: 'عرض الباقات',
                  onPressed: () async {
                    final uri =
                        Uri.parse('${AppConfig.apiBase}/workspace/billing');
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                ),
                TextButton(
                  onPressed: () async {
                    await ref.read(authControllerProvider.notifier).logout();
                    if (context.mounted) context.go('/login');
                  },
                  child: const Text('تسجيل الخروج / تغيير الحساب'),
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
  try {
    final data = await ref.read(cashierApiProvider).get('/bootstrap');
    return data['pos_enabled'] == true;
  } on ApiException catch (e) {
    if (e.statusCode == 403) return false;
    rethrow;
  }
}
