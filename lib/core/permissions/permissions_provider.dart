import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Permissions snapshot from `/bootstrap` (Laravel source of truth).
final cashierPermissionsProvider =
    StateProvider<Map<String, dynamic>>((ref) => {});
