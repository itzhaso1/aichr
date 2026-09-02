import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Requested shell tab from child features (e.g. Tables → Cashier after "إضافة طلب").
enum PosShellTab {
  cashier,
  tables,
  orders,
  menu,
  kitchen,
  invoices,
  customers,
  items,
  reports,
  sync,
  settings,
}

final posShellNavProvider = StateProvider<PosShellTab?>((ref) => null);

void requestPosShellTab(WidgetRef ref, PosShellTab tab) {
  ref.read(posShellNavProvider.notifier).state = tab;
}
