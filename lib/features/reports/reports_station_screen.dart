import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/hasim_colors.dart';
import 'daily_reports_panel.dart';

/// Isolated reports station — reachable from login under the kitchen entry.
class ReportsStationScreen extends ConsumerWidget {
  const ReportsStationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).valueOrNull;

    return Scaffold(
      backgroundColor: HasimColors.page,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('التقارير'),
            Text(
              session == null || session.userName.isEmpty
                  ? 'محطة التقارير — ملخص المبيعات المحلية'
                  : 'مرحباً ${session.userName}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: HasimColors.muted,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => context.go('/kitchen'),
            child: const Text('المطبخ'),
          ),
          if (session?.canUsePos == true)
            TextButton(
              onPressed: () => context.go('/home'),
              child: const Text('الكاشير'),
            ),
          TextButton.icon(
            onPressed: () async {
              if (session != null) {
                await ref.read(authControllerProvider.notifier).logout();
              }
              if (context.mounted) context.go('/login');
            },
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('خروج'),
          ),
        ],
      ),
      body: const SizedBox.expand(child: DailyReportsPanel()),
    );
  }
}
