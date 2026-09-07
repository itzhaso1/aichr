import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/permissions/cashier_permissions.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';
import 'daily_reports_panel.dart';

/// Isolated reports station — login + reports.view required.
class ReportsStationScreen extends ConsumerWidget {
  const ReportsStationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).valueOrNull;
    final allowed = CashierPermissions.canViewReports(session?.permissions);

    return Scaffold(
      backgroundColor: HasimColors.page,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('التقارير'),
            Text(
              session == null
                  ? 'يتطلب تسجيل الدخول'
                  : 'مرحباً ${session.userName.isEmpty ? 'المستخدم' : session.userName}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: HasimColors.muted,
              ),
            ),
          ],
        ),
        actions: [
          if (session?.canUsePos == true)
            TextButton(
              onPressed: () => context.go('/home'),
              child: const Text('الكاشير'),
            ),
          TextButton.icon(
            onPressed: () async {
              await ref.read(authControllerProvider.notifier).logout();
              if (context.mounted) context.go('/login');
            },
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('خروج'),
          ),
        ],
      ),
      body: ColoredBox(
        color: HasimColors.page,
        child: !allowed
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: HsEmpty(
                  title: 'غير مصرح بعرض التقارير',
                  subtitle:
                      'لا تملك صلاحية الدخول إلى صفحة التقارير. اطلبها من المدير.',
                ),
              )
            : const DailyReportsPanel(),
      ),
    );
  }
}
