import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';
import 'daily_reports_panel.dart';

/// Isolated reports station — reachable from login under the kitchen entry.
class ReportsStationScreen extends ConsumerWidget {
  const ReportsStationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Select primitives only so auth loading/rebuilds do not recreate AppBar
    // InkWell/MouseRegion annotations under a live Windows cursor.
    final userName = ref.watch(
      authControllerProvider.select((s) => s.valueOrNull?.userName),
    );
    final canUsePos = ref.watch(
      authControllerProvider.select(
        (s) => s.valueOrNull?.canUsePos == true,
      ),
    );

    return Scaffold(
      backgroundColor: HasimColors.page,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('التقارير'),
            Text(
              userName == null || userName.isEmpty
                  ? 'محطة التقارير — ملخص المبيعات المحلية'
                  : 'مرحباً $userName',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: HasimColors.muted,
              ),
            ),
          ],
        ),
        actions: [
          HsTextAction(
            label: 'المطبخ',
            onTap: () => context.go('/kitchen'),
          ),
          if (canUsePos)
            HsTextAction(
              label: 'الكاشير',
              onTap: () => context.go('/home'),
            ),
          HsTextAction(
            label: 'خروج',
            icon: Icons.logout,
            color: HasimColors.ink,
            onTap: () async {
              final session = ref.read(authControllerProvider).valueOrNull;
              if (session != null) {
                await ref.read(authControllerProvider.notifier).logout();
              }
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
      body: const SizedBox.expand(child: DailyReportsPanel()),
    );
  }
}
