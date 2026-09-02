import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../pos/pos_mode.dart';
import 'tables.dart';
import 'workspace_scope.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    LocalDevices,
    LocalCategories,
    LocalProducts,
    LocalTables,
    LocalCustomers,
    LocalOrders,
    LocalOrderItems,
    LocalStockMovements,
    LocalPayments,
    LocalInvoices,
    LocalSettings,
    LocalPermissions,
    SyncQueueItems,
    SyncConflicts,
    SyncMetadata,
    LocalStores,
    LocalUsers,
    LocalSequences,
    LocalSessions,
    LocalDraftCarts,
    LocalDraftCartLines,
    LocalReturns,
    LocalReturnItems,
    LocalShifts,
    LocalCashMovements,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createPerfIndexes();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
    onUpgrade: (m, from, to) async {
      if (from < 3) {
        await _createPerfIndexes();
      }
      if (from < 4) {
        await m.createTable(localStockMovements);
        await m.addColumn(localProducts, localProducts.stock);
        await m.addColumn(syncQueueItems, syncQueueItems.operationUuid);
        await m.addColumn(syncQueueItems, syncQueueItems.syncedAt);
        await _createPerfIndexes();
      }
      if (from < 5) {
        await m.createTable(localStores);
        await m.createTable(localUsers);
        await m.createTable(localSequences);
        await m.createTable(localSessions);
        await m.createTable(localDraftCarts);
        await m.createTable(localDraftCartLines);
        await m.createTable(localReturns);
        await m.createTable(localReturnItems);
        await m.createTable(localShifts);
        await m.createTable(localCashMovements);
        await _addColumnIfMissing(
          m,
          localCategories,
          localCategories.createdAt,
        );
        await _addColumnIfMissing(m, localProducts, localProducts.cost);
        await _addColumnIfMissing(m, localProducts, localProducts.taxRate);
        await _addColumnIfMissing(m, localProducts, localProducts.trackStock);
        await _addColumnIfMissing(m, localProducts, localProducts.imagePath);
        await _addColumnIfMissing(m, localProducts, localProducts.createdAt);
        await _addColumnIfMissing(m, localTables, localTables.tableNumber);
        await _addColumnIfMissing(m, localTables, localTables.createdAt);
        await _addColumnIfMissing(m, localCustomers, localCustomers.email);
        await _addColumnIfMissing(m, localCustomers, localCustomers.notes);
        await _addColumnIfMissing(m, localCustomers, localCustomers.createdAt);
        await _addColumnIfMissing(m, localOrders, localOrders.orderNumber);
        await _addColumnIfMissing(m, localOrders, localOrders.sessionLocalId);
        await _addColumnIfMissing(m, localOrders, localOrders.customerLocalId);
        await _addColumnIfMissing(m, localOrders, localOrders.createdByUserId);
        await _addColumnIfMissing(
          m,
          localOrders,
          localOrders.fulfillmentStatus,
        );
        await _addColumnIfMissing(m, localOrders, localOrders.discountPercent);
        await _addColumnIfMissing(m, localOrders, localOrders.completedAt);
        await _addColumnIfMissing(
          m,
          localOrderItems,
          localOrderItems.skuSnapshot,
        );
        await _addColumnIfMissing(
          m,
          localOrderItems,
          localOrderItems.barcodeSnapshot,
        );
        await _addColumnIfMissing(
          m,
          localOrderItems,
          localOrderItems.costSnapshot,
        );
        await _addColumnIfMissing(m, localOrderItems, localOrderItems.taxRate);
        await _addColumnIfMissing(
          m,
          localOrderItems,
          localOrderItems.taxAmount,
        );
        await _addColumnIfMissing(m, localOrderItems, localOrderItems.notes);
        await _addColumnIfMissing(
          m,
          localOrderItems,
          localOrderItems.createdAt,
        );
        await _addColumnIfMissing(
          m,
          localStockMovements,
          localStockMovements.beforeQuantity,
        );
        await _addColumnIfMissing(
          m,
          localStockMovements,
          localStockMovements.afterQuantity,
        );
        await _addColumnIfMissing(
          m,
          localStockMovements,
          localStockMovements.userId,
        );
        await _addColumnIfMissing(m, localPayments, localPayments.tendered);
        await _addColumnIfMissing(m, localPayments, localPayments.changeDue);
        await _addColumnIfMissing(m, localPayments, localPayments.shiftLocalId);
        await _addColumnIfMissing(
          m,
          localInvoices,
          localInvoices.localInvoiceNumber,
        );
        await _addColumnIfMissing(
          m,
          localInvoices,
          localInvoices.serverInvoiceNumber,
        );
        await _addColumnIfMissing(m, localInvoices, localInvoices.orderLocalId);
        await _addColumnIfMissing(m, localInvoices, localInvoices.status);
        await _addColumnIfMissing(m, localInvoices, localInvoices.subtotal);
        await _addColumnIfMissing(
          m,
          localInvoices,
          localInvoices.discountAmount,
        );
        await _addColumnIfMissing(m, localInvoices, localInvoices.taxAmount);
        await _addColumnIfMissing(
          m,
          localInvoices,
          localInvoices.createdByUserId,
        );
        await _createPerfIndexes();
      }
      if (from < 6) {
        await remapLegacyStandaloneWorkspaceIfNeeded();
        await _createPerfIndexes();
      }
      if (from < 7) {
        await migrateToIntegerMoneyAndForeignKeys(m);
        await _createPerfIndexes();
      }
    },
  );

  static const _moneyColumns = {
    'local_products': {'price', 'cost'},
    'local_orders': {
      'subtotal',
      'tax_amount',
      'discount_amount',
      'total_amount',
    },
    'local_order_items': {
      'unit_price',
      'cost_snapshot',
      'discount_amount',
      'tax_amount',
      'total_amount',
    },
    'local_payments': {'amount', 'tendered', 'change_due'},
    'local_invoices': {
      'subtotal',
      'discount_amount',
      'tax_amount',
      'total_amount',
    },
    'local_sessions': {'discount_amount'},
    'local_draft_carts': {'discount_amount'},
    'local_draft_cart_lines': {'unit_price', 'cost', 'discount_amount'},
    'local_returns': {'refund_amount'},
    'local_return_items': {'refund_amount'},
    'local_shifts': {
      'opening_cash',
      'closing_cash',
      'expected_cash',
      'actual_cash',
      'difference',
    },
    'local_cash_movements': {'amount'},
  };

  /// v7: convert REAL major-units to INTEGER cents and rebuild FK tables.
  Future<void> migrateToIntegerMoneyAndForeignKeys(Migrator m) async {
    await customStatement('PRAGMA foreign_keys = OFF');
    await _deleteOrphanChildren();
    final tables = <TableInfo>[
      localProducts,
      localSequences,
      localSessions,
      localShifts,
      localOrders,
      localOrderItems,
      localInvoices,
      localPayments,
      localReturns,
      localReturnItems,
      localStockMovements,
      localCashMovements,
      localDraftCarts,
      localDraftCartLines,
    ];
    for (final table in tables) {
      await _rebuildTableWithCents(m, table);
    }
    await _nullDanglingForeignKeys();
    await customStatement('PRAGMA foreign_keys = ON');
  }

  Future<void> _deleteOrphanChildren() async {
    await _sqlIf(['local_order_items', 'local_orders'],
      'DELETE FROM local_order_items WHERE order_local_id NOT IN '
      '(SELECT local_id FROM local_orders)',
    );
    await _sqlIf(['local_order_items', 'local_products'],
      'UPDATE local_order_items SET product_local_id = NULL '
      'WHERE product_local_id IS NOT NULL AND product_local_id NOT IN '
      '(SELECT local_id FROM local_products)',
    );
    await _sqlIf(['local_orders', 'local_tables'],
      'UPDATE local_orders SET table_local_id = NULL '
      'WHERE table_local_id IS NOT NULL AND table_local_id NOT IN '
      '(SELECT local_id FROM local_tables)',
    );
    await _sqlIf(['local_orders', 'local_sessions'],
      'UPDATE local_orders SET session_local_id = NULL '
      'WHERE session_local_id IS NOT NULL AND session_local_id NOT IN '
      '(SELECT local_id FROM local_sessions)',
    );
    await _sqlIf(['local_orders', 'local_customers'],
      'UPDATE local_orders SET customer_local_id = NULL '
      'WHERE customer_local_id IS NOT NULL AND customer_local_id NOT IN '
      '(SELECT local_id FROM local_customers)',
    );
    await _sqlIf(['local_orders', 'local_users'],
      'UPDATE local_orders SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_invoices', 'local_orders'],
      'UPDATE local_invoices SET order_local_id = NULL '
      'WHERE order_local_id IS NOT NULL AND order_local_id NOT IN '
      '(SELECT local_id FROM local_orders)',
    );
    await _sqlIf(['local_invoices', 'local_users'],
      'UPDATE local_invoices SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_payments', 'local_orders'],
      'UPDATE local_payments SET order_local_id = NULL '
      'WHERE order_local_id IS NOT NULL AND order_local_id NOT IN '
      '(SELECT local_id FROM local_orders)',
    );
    await _sqlIf(['local_payments', 'local_invoices'],
      'UPDATE local_payments SET invoice_local_id = NULL '
      'WHERE invoice_local_id IS NOT NULL AND invoice_local_id NOT IN '
      '(SELECT local_id FROM local_invoices)',
    );
    await _sqlIf(['local_payments', 'local_shifts'],
      'UPDATE local_payments SET shift_local_id = NULL '
      'WHERE shift_local_id IS NOT NULL AND shift_local_id NOT IN '
      '(SELECT local_id FROM local_shifts)',
    );
    await _sqlIf(['local_return_items', 'local_returns'],
      'DELETE FROM local_return_items WHERE return_local_id NOT IN '
      '(SELECT local_id FROM local_returns)',
    );
    await _sqlIf(['local_returns', 'local_invoices'],
      'UPDATE local_returns SET invoice_local_id = NULL '
      'WHERE invoice_local_id IS NOT NULL AND invoice_local_id NOT IN '
      '(SELECT local_id FROM local_invoices)',
    );
    await _sqlIf(['local_returns', 'local_orders'],
      'UPDATE local_returns SET order_local_id = NULL '
      'WHERE order_local_id IS NOT NULL AND order_local_id NOT IN '
      '(SELECT local_id FROM local_orders)',
    );
    await _sqlIf(['local_returns', 'local_shifts'],
      'UPDATE local_returns SET shift_local_id = NULL '
      'WHERE shift_local_id IS NOT NULL AND shift_local_id NOT IN '
      '(SELECT local_id FROM local_shifts)',
    );
    await _sqlIf(['local_returns', 'local_users'],
      'UPDATE local_returns SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_return_items', 'local_order_items'],
      'UPDATE local_return_items SET order_item_local_id = NULL '
      'WHERE order_item_local_id IS NOT NULL AND order_item_local_id NOT IN '
      '(SELECT local_id FROM local_order_items)',
    );
    await _sqlIf(['local_return_items', 'local_products'],
      'UPDATE local_return_items SET product_local_id = NULL '
      'WHERE product_local_id IS NOT NULL AND product_local_id NOT IN '
      '(SELECT local_id FROM local_products)',
    );
    await _sqlIf(['local_stock_movements', 'local_products'],
      'UPDATE local_stock_movements SET product_local_id = NULL '
      'WHERE product_local_id IS NOT NULL AND product_local_id NOT IN '
      '(SELECT local_id FROM local_products)',
    );
    await _sqlIf(['local_cash_movements', 'local_users'],
      'UPDATE local_cash_movements SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_cash_movements', 'local_shifts'],
      'DELETE FROM local_cash_movements WHERE shift_local_id NOT IN '
      '(SELECT local_id FROM local_shifts)',
    );
    await _sqlIf(['local_sequences', 'local_stores'],
      'DELETE FROM local_sequences WHERE store_id NOT IN '
      '(SELECT local_id FROM local_stores)',
    );
    await _sqlIf(['local_sessions', 'local_tables'],
      'DELETE FROM local_sessions WHERE table_local_id NOT IN '
      '(SELECT local_id FROM local_tables)',
    );
    await _sqlIf(['local_draft_cart_lines', 'local_draft_carts'],
      'DELETE FROM local_draft_cart_lines WHERE cart_local_id NOT IN '
      '(SELECT local_id FROM local_draft_carts)',
    );
    await _sqlIf(['local_draft_cart_lines', 'local_products'],
      'DELETE FROM local_draft_cart_lines WHERE product_local_id NOT IN '
      '(SELECT local_id FROM local_products)',
    );
    await _sqlIf(['local_draft_carts', 'local_tables'],
      'UPDATE local_draft_carts SET table_local_id = NULL '
      'WHERE table_local_id IS NOT NULL AND table_local_id NOT IN '
      '(SELECT local_id FROM local_tables)',
    );
    await _sqlIf(['local_draft_carts', 'local_customers'],
      'UPDATE local_draft_carts SET customer_local_id = NULL '
      'WHERE customer_local_id IS NOT NULL AND customer_local_id NOT IN '
      '(SELECT local_id FROM local_customers)',
    );
  }

  Future<void> _nullDanglingForeignKeys() async {
    await _sqlIf(['local_products', 'local_categories'],
      'UPDATE local_products SET category_local_id = NULL '
      'WHERE category_local_id IS NOT NULL AND category_local_id NOT IN '
      '(SELECT local_id FROM local_categories)',
    );
    await _sqlIf(['local_shifts', 'local_users'],
      'UPDATE local_shifts SET user_id = NULL '
      'WHERE user_id IS NOT NULL AND user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_order_items', 'local_products'],
      'UPDATE local_order_items SET product_local_id = NULL '
      'WHERE product_local_id IS NOT NULL AND product_local_id NOT IN '
      '(SELECT local_id FROM local_products)',
    );
    await _sqlIf(['local_orders', 'local_tables'],
      'UPDATE local_orders SET table_local_id = NULL '
      'WHERE table_local_id IS NOT NULL AND table_local_id NOT IN '
      '(SELECT local_id FROM local_tables)',
    );
    await _sqlIf(['local_orders', 'local_sessions'],
      'UPDATE local_orders SET session_local_id = NULL '
      'WHERE session_local_id IS NOT NULL AND session_local_id NOT IN '
      '(SELECT local_id FROM local_sessions)',
    );
    await _sqlIf(['local_orders', 'local_customers'],
      'UPDATE local_orders SET customer_local_id = NULL '
      'WHERE customer_local_id IS NOT NULL AND customer_local_id NOT IN '
      '(SELECT local_id FROM local_customers)',
    );
    await _sqlIf(['local_orders', 'local_users'],
      'UPDATE local_orders SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_invoices', 'local_users'],
      'UPDATE local_invoices SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_returns', 'local_users'],
      'UPDATE local_returns SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_cash_movements', 'local_users'],
      'UPDATE local_cash_movements SET created_by_user_id = NULL '
      'WHERE created_by_user_id IS NOT NULL AND created_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_sessions', 'local_users'],
      'UPDATE local_sessions SET opened_by_user_id = NULL '
      'WHERE opened_by_user_id IS NOT NULL AND opened_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
    await _sqlIf(['local_sessions', 'local_users'],
      'UPDATE local_sessions SET closed_by_user_id = NULL '
      'WHERE closed_by_user_id IS NOT NULL AND closed_by_user_id NOT IN '
      '(SELECT local_id FROM local_users)',
    );
  }

  Future<void> _rebuildTableWithCents(Migrator m, TableInfo table) async {
    final name = table.actualTableName;
    final exists = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    if (exists.isEmpty) {
      await m.createTable(table);
      return;
    }
    final oldName = '${name}__v6';
    await customStatement('ALTER TABLE $name RENAME TO $oldName');
    await m.createTable(table);
    final oldCols = await customSelect('PRAGMA table_info($oldName)').get();
    final newCols = await customSelect('PRAGMA table_info($name)').get();
    final oldNames = {for (final c in oldCols) '${c.data['name']}'};
    final newNames = [for (final c in newCols) '${c.data['name']}'];
    final shared = [for (final n in newNames) if (oldNames.contains(n)) n];
    if (shared.isEmpty) {
      await customStatement('DROP TABLE $oldName');
      return;
    }
    final money = _moneyColumns[name] ?? const <String>{};
    final selects = [
      for (final n in shared)
        money.contains(n)
            ? 'CAST(ROUND(COALESCE($n, 0) * 100.0) AS INTEGER)'
            : n,
    ];
    await customStatement(
      'INSERT INTO $name (${shared.join(',')}) '
      'SELECT ${selects.join(',')} FROM $oldName',
    );
    await customStatement('DROP TABLE $oldName');
  }

  /// Remap pre-audit standalone rows from Laravel-looking workspace `1`
  /// to the reserved standalone scope. Never remaps a connected / synced store.
  Future<void> remapLegacyStandaloneWorkspaceIfNeeded() async {
    if (!await _hasTable('local_stores')) return;
    final stores = await customSelect(
      'SELECT local_id, workspace_id, connected_mode FROM local_stores '
      'WHERE workspace_id = ?',
      variables: [Variable.withInt(PosMode.legacyCollidingWorkspaceId)],
    ).get();
    if (stores.isEmpty) return;
    final connected = stores.first.data['connected_mode'];
    if (connected == 1 || connected == true) return;
    if (await _hasTable('sync_metadata')) {
      final sync = await customSelect(
        'SELECT value FROM sync_metadata WHERE workspace_id = ? AND key = ?',
        variables: [
          Variable.withInt(PosMode.legacyCollidingWorkspaceId),
          Variable.withString(SyncMetaKeys.initialSyncCompleted),
        ],
      ).get();
      if (sync.isNotEmpty && '${sync.first.data['value']}' == '1') return;
    }

    final already = await customSelect(
      'SELECT local_id FROM local_stores WHERE workspace_id = ?',
      variables: [Variable.withInt(PosMode.standaloneWorkspaceId)],
    ).get();
    if (already.isNotEmpty) return;

    final tables = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    ).get();
    for (final table in tables) {
      final name = '${table.data['name']}';
      final cols = await customSelect('PRAGMA table_info($name)').get();
      final hasWorkspace = cols.any((c) => '${c.data['name']}' == 'workspace_id');
      if (!hasWorkspace) continue;
      await customStatement(
        'UPDATE $name SET workspace_id = ? WHERE workspace_id = ?',
        [
          PosMode.standaloneWorkspaceId,
          PosMode.legacyCollidingWorkspaceId,
        ],
      );
    }
  }

  Future<void> _addColumnIfMissing(
    Migrator m,
    TableInfo table,
    GeneratedColumn column,
  ) async {
    try {
      await m.addColumn(table, column);
    } catch (_) {
      // Column already exists on some migrated databases.
    }
  }

  Future<void> _createPerfIndexes() async {
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_orders_ws_sync '
      'ON local_orders (workspace_id, sync_status)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_orders_ws_client_ref '
      'ON local_orders (workspace_id, client_reference)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_order_items_order '
      'ON local_order_items (workspace_id, order_local_id)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_products_ws '
      'ON local_products (workspace_id, is_deleted, is_active)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_ws_status '
      'ON sync_queue_items (workspace_id, status, next_attempt_at)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_customers_ws '
      'ON local_customers (workspace_id, sync_status)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_orders_ws_table '
      'ON local_orders (workspace_id, table_server_id)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_tables_ws_server '
      'ON local_tables (workspace_id, server_id)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_sync_conflicts_ws_status '
      'ON sync_conflicts (workspace_id, status)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_stock_movements_ws '
      'ON local_stock_movements (workspace_id, created_at)',
    );
    await _safeIndex(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_queue_operation_uuid '
      'ON sync_queue_items (workspace_id, operation_uuid) '
      'WHERE operation_uuid IS NOT NULL',
    );
    await _safeIndex(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_local_stores_workspace '
      'ON local_stores (workspace_id)',
    );
    await _safeIndex(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_local_users_ws_username '
      'ON local_users (workspace_id, username)',
    );
    await _safeIndex(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_local_invoices_local_number '
      'ON local_invoices (workspace_id, local_invoice_number) '
      'WHERE local_invoice_number IS NOT NULL',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_sessions_ws_table '
      'ON local_sessions (workspace_id, table_local_id, status)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_shifts_ws_status '
      'ON local_shifts (workspace_id, status)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_draft_lines_cart '
      'ON local_draft_cart_lines (cart_local_id)',
    );
    await _safeIndex(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_local_orders_ws_client_ref_uq '
      'ON local_orders (workspace_id, client_reference)',
    );
    await _safeIndex(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_local_orders_ws_number_uq '
      'ON local_orders (workspace_id, order_number) '
      'WHERE order_number IS NOT NULL',
    );
    await _safeIndex(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_local_shifts_one_open '
      'ON local_shifts (workspace_id) WHERE status = \'open\'',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_products_barcode '
      'ON local_products (workspace_id, barcode)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_products_sku '
      'ON local_products (workspace_id, sku)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_invoices_ws_created '
      'ON local_invoices (workspace_id, created_at)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_orders_ws_created '
      'ON local_orders (workspace_id, created_at)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_payments_ws_created '
      'ON local_payments (workspace_id, created_at)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_returns_ws_created '
      'ON local_returns (workspace_id, created_at)',
    );
    await _safeIndex(
      'CREATE INDEX IF NOT EXISTS idx_local_return_items_return '
      'ON local_return_items (return_local_id)',
    );
  }

  /// Production/native opener — one SQLite file per app install.
  static AppDatabase open() {
    return AppDatabase(
      LazyDatabase(() async {
        final dir = await getApplicationDocumentsDirectory();
        final file = File(p.join(dir.path, 'hasim_cashier_pos_v2.sqlite'));
        return NativeDatabase.createInBackground(file);
      }),
    );
  }

  /// In-memory DB for unit tests.
  static AppDatabase memory() => AppDatabase(NativeDatabase.memory());

  /// File-backed DB for restart / durability tests.
  static AppDatabase file(File file) => AppDatabase(NativeDatabase(file));

  /// Returns [id] only when the parent row exists. Connected-mode writers
  /// mint synthetic ids before the parent is pulled; those become NULL so
  /// SQLite foreign keys stay valid. Server ids remain the correlation key.
  Future<String?> existingFk(
    String tableName,
    String column,
    String? id,
  ) async {
    if (id == null || id.isEmpty) return null;
    final rows = await customSelect(
      'SELECT 1 FROM $tableName WHERE $column = ? LIMIT 1',
      variables: [Variable.withString(id)],
    ).get();
    return rows.isEmpty ? null : id;
  }

  Future<bool> _hasTable(String name) async {
    final rows = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<void> _sqlIf(List<String> tables, String sql) async {
    for (final table in tables) {
      if (!await _hasTable(table)) return;
    }
    await customStatement(sql);
  }

  Future<void> _safeIndex(String sql) async {
    try {
      await customStatement(sql);
    } catch (_) {
      // Table may be missing on incomplete pre-v7 files; createTable later.
    }
  }
}
