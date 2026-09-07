import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/hasim_colors.dart';
import 'kitchen_board.dart';

/// Isolated chef station — reachable from login without cashier credentials.
class KitchenStationScreen extends ConsumerWidget {
  const KitchenStationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).valueOrNull;
    final chefName = session?.isKitchenSession == true ? session!.userName : null;

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
          TextButton(
            onPressed: () => context.go('/reports'),
            child: const Text('التقارير'),
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
      body: const KitchenBoard(),
    );
  }
}
