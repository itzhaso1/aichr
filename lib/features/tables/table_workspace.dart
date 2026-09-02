import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Currently opened table workspace (full-screen detail). Null = tables board.
final openTableIdProvider = StateProvider<int?>((ref) => null);

void openTableWorkspace(WidgetRef ref, int tableId) {
  ref.read(openTableIdProvider.notifier).state = tableId;
}

void closeTableWorkspace(WidgetRef ref) {
  ref.read(openTableIdProvider.notifier).state = null;
}
