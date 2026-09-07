import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/widgets/hasim_widgets.dart';
import 'kitchen_board.dart';

/// Isolated chef station — reachable from login without cashier credentials.
class KitchenStationScreen extends ConsumerWidget {
  const KitchenStationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chefName = ref.watch(
      authControllerProvider.select((s) {
        final session = s.valueOrNull;
        if (session == null || !session.isKitchenSession) return null;
        return session.userName;
      }),
    );
    final canUsePos = ref.watch(
      authControllerProvider.select(
        (s) => s.valueOrNull?.canUsePos == true,
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('المطبخ'),
            Text(
              chefName == null || chefName.isEmpty
                  ? 'محطة الشيف — طلبات التجهيز فقط'
                  : 'شيف: $chefName',
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
            label: 'التقارير',
            onTap: () => context.go('/reports'),
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
      body: const KitchenBoard(),
    );
  }
}
