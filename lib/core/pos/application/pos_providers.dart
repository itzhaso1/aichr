import 'barcode_input.dart';
import 'backup_service.dart';
import 'catalog_admin_service.dart';
import 'checkout_service.dart';
import 'document_numbers.dart';
import 'draft_cart_store.dart';
import 'hive_legacy_migration.dart';
import 'kitchen_local_service.dart';
import 'local_auth_service.dart';
import 'reports_service.dart';
import 'return_service.dart';
import 'session_service.dart';
import 'shift_service.dart';
import 'stock_engine.dart';
import '../../local_db/local_db_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final documentNumberServiceProvider = Provider<DocumentNumberService>((ref) {
  return DocumentNumberService(ref.watch(appDatabaseProvider));
});

final stockEngineProvider = Provider<StockEngine>((ref) {
  return StockEngine(ref.watch(appDatabaseProvider));
});

final checkoutServiceProvider = Provider<CheckoutService>((ref) {
  return CheckoutService(
    ref.watch(appDatabaseProvider),
    ref.watch(stockEngineProvider),
    ref.watch(documentNumberServiceProvider),
    ref.watch(syncQueueRepositoryProvider),
  );
});

final returnServiceProvider = Provider<ReturnService>((ref) {
  return ReturnService(
    ref.watch(appDatabaseProvider),
    ref.watch(stockEngineProvider),
  );
});

final shiftServiceProvider = Provider<ShiftService>((ref) {
  return ShiftService(ref.watch(appDatabaseProvider));
});

final catalogAdminServiceProvider = Provider<CatalogAdminService>((ref) {
  return CatalogAdminService(ref.watch(appDatabaseProvider));
});

final draftCartStoreProvider = Provider<DraftCartStore>((ref) {
  return DraftCartStore(ref.watch(appDatabaseProvider));
});

final localReportsServiceProvider = Provider<LocalReportsService>((ref) {
  return LocalReportsService(ref.watch(appDatabaseProvider));
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref.watch(appDatabaseProvider));
});

final localAuthServiceProvider = Provider<LocalAuthService>((ref) {
  return LocalAuthService(ref.watch(appDatabaseProvider));
});

final hiveLegacyMigrationProvider = Provider<HiveLegacyMigration>((ref) {
  return HiveLegacyMigration(
    ref.watch(appDatabaseProvider),
    ref.watch(ordersRepositoryProvider),
  );
});

final tableSessionServiceProvider = Provider<TableSessionService>((ref) {
  return TableSessionService(ref.watch(appDatabaseProvider));
});

final kitchenLocalServiceProvider = Provider<KitchenLocalService>((ref) {
  return KitchenLocalService(ref.watch(appDatabaseProvider));
});

final barcodeInputProvider = Provider<BarcodeInput>((ref) {
  return BarcodeInput(ref.watch(catalogAdminServiceProvider));
});

final currentShiftIdProvider = StateProvider<String?>((ref) => null);
final currentLocalUserIdProvider = StateProvider<String?>((ref) => null);
final currentStoreIdProvider = StateProvider<String?>((ref) => null);
final posConnectedModeProvider = StateProvider<bool>((ref) => false);
