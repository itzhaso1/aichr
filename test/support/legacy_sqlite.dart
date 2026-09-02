import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Builds a pre-v7 Hasim POS SQLite file (REAL money, no foreign keys).
void writeLegacyPosDatabase({
  required File file,
  required int userVersion,
  int workspaceId = 1,
}) {
  if (file.existsSync()) file.deleteSync();
  final db = sqlite3.open(file.path);
  db.execute('PRAGMA foreign_keys = OFF');
  db.execute('PRAGMA user_version = $userVersion');
  for (final sql in _createSql) {
    db.execute(sql);
  }
  // Drift stores DateTime as UNIX seconds (not ms/µs).
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  db.execute(
    '''
    INSERT INTO local_stores (local_id, workspace_id, name, currency, timezone,
      tax_rate, allow_negative_stock, invoice_prefix, connected_mode,
      created_at, updated_at)
    VALUES ('store-1', ?, 'قديم', 'SAR', 'Asia/Riyadh', 15.0, 0, 'INV-', 0, ?, ?);
    ''',
    [workspaceId, now, now],
  );
  db.execute(
    '''
    INSERT INTO local_users (local_id, workspace_id, name, username, pin_salt,
      pin_hash, role, is_active, created_at, updated_at)
    VALUES ('user-1', ?, 'مدير', 'admin', 'c2FsdA==',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'admin', 1, ?, ?);
    ''',
    [workspaceId, now, now],
  );
  db.execute(
    '''
    INSERT INTO local_categories (local_id, workspace_id, name, sort_order,
      is_active, is_deleted, created_at, updated_at)
    VALUES ('cat-1', ?, 'مشروبات', 0, 1, 0, ?, ?);
    ''',
    [workspaceId, now, now],
  );
  db.execute(
    '''
    INSERT INTO local_products (local_id, workspace_id, category_local_id, name,
      barcode, price, is_active, is_deleted, payload_json, stock, cost,
      tax_rate, track_stock, created_at, updated_at)
    VALUES ('prod-1', ?, 'cat-1', 'شاي', '999', 10.5, 1, 0, '{}', 20, 3.25,
      15.0, 1, ?, ?);
    ''',
    [workspaceId, now, now],
  );
  db.execute(
    '''
    INSERT INTO local_customers (local_id, workspace_id, name, phone,
      payload_json, created_at, updated_at, sync_status)
    VALUES ('cust-1', ?, 'عميل', '0500000000', '{}', ?, ?, 'synced');
    ''',
    [workspaceId, now, now],
  );
  db.execute(
    '''
    INSERT INTO local_tables (local_id, workspace_id, name, status,
      payload_json, created_at, updated_at)
    VALUES ('table-1', ?, 'T1', 'available', '{}', ?, ?);
    ''',
    [workspaceId, now, now],
  );
  db.execute(
    '''
    INSERT INTO local_sequences (store_id, kind, next_value, updated_at)
    VALUES ('store-1', 'invoice', 8, ?);
    ''',
    [now],
  );
  db.execute(
    '''
    INSERT INTO local_shifts (local_id, workspace_id, user_id, opened_at,
      opening_cash, status)
    VALUES ('shift-1', ?, 'user-1', ?, 100.0, 'open');
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_cash_movements (local_id, workspace_id, shift_local_id,
      type, amount, reason, created_by_user_id, created_at)
    VALUES ('cash-1', ?, 'shift-1', 'opening', 100.0, 'افتتاح', 'user-1', ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_orders (local_id, workspace_id, device_id, client_reference,
      order_number, order_type, customer_local_id, created_by_user_id, notes,
      subtotal, tax_amount, discount_amount, discount_percent, total_amount,
      pos_status, payment_status, fulfillment_status, sync_status, retry_count,
      created_at, updated_at)
    VALUES ('order-1', ?, 'dev-1', 'order-1', 'ORD-000001', 'takeaway',
      'cust-1', 'user-1', NULL, 10.5, 1.58, 0.0, 0.0, 12.08, 'completed',
      'paid', 'unfulfilled', 'local', 0, ?, ?);
    ''',
    [workspaceId, now, now],
  );
  db.execute(
    '''
    INSERT INTO local_order_items (local_id, workspace_id, order_local_id,
      product_local_id, name, quantity, unit_price, cost_snapshot,
      discount_amount, tax_rate, tax_amount, total_amount, is_removed, updated_at)
    VALUES ('item-1', ?, 'order-1', 'prod-1', 'شاي', 1, 10.5, 3.25, 0.0, 15.0,
      1.58, 12.08, 0, ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_invoices (local_id, workspace_id, device_id,
      invoice_number, local_invoice_number, order_local_id, status, subtotal,
      discount_amount, tax_amount, total_amount, created_by_user_id, sync_status,
      payload_json, created_at)
    VALUES ('inv-1', ?, 'dev-1', 'INV-000007', 'INV-000007', 'order-1', 'closed',
      10.5, 0.0, 1.58, 12.08, 'user-1', 'local', '{}', ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_payments (local_id, workspace_id, device_id,
      order_local_id, invoice_local_id, method, amount, tendered, change_due,
      shift_local_id, sync_status, client_reference, created_at)
    VALUES ('pay-1', ?, 'dev-1', 'order-1', 'inv-1', 'cash', 12.08, 20.0, 7.92,
      'shift-1', 'local', 'order-1:cash', ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_returns (local_id, workspace_id, invoice_local_id,
      order_local_id, reason, refund_amount, status, created_by_user_id,
      shift_local_id, created_at)
    VALUES ('ret-1', ?, 'inv-1', 'order-1', 'تجربة', 12.08, 'completed',
      'user-1', 'shift-1', ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_return_items (local_id, return_local_id, workspace_id,
      order_item_local_id, product_local_id, product_name_snapshot, quantity,
      refund_amount)
    VALUES ('ri-1', 'ret-1', ?, 'item-1', 'prod-1', 'شاي', 1, 12.08);
    ''',
    [workspaceId],
  );
  db.execute(
    '''
    INSERT INTO local_stock_movements (local_id, workspace_id, device_id,
      product_local_id, kind, quantity, before_quantity, after_quantity,
      reference_type, reference_id, user_id, sync_status, client_reference,
      payload_json, created_at)
    VALUES ('sm-1', ?, 'dev-1', 'prod-1', 'sale', 1, 21, 20, 'order', 'order-1',
      'user-1', 'local', 'sm-1', '{}', ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_draft_carts (local_id, workspace_id, channel,
      discount_amount, discount_percent, tax_rate, updated_at)
    VALUES ('draft-1', ?, 'takeaway', 1.5, 0.0, 15.0, ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_draft_cart_lines (local_id, cart_local_id, workspace_id,
      product_local_id, name, quantity, unit_price, cost, discount_amount,
      tax_rate, updated_at)
    VALUES ('dl-1', 'draft-1', ?, 'prod-1', 'شاي', 2, 10.5, 3.25, 0.0, 15.0, ?);
    ''',
    [workspaceId, now],
  );
  db.execute(
    '''
    INSERT INTO local_settings (key, workspace_id, value_json, updated_at)
    VALUES ('tax_rate', ?, '15', ?);
    ''',
    [workspaceId, now],
  );
  db.dispose();
}

const _createSql = [
  '''
  CREATE TABLE local_stores (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'SAR',
    timezone TEXT NOT NULL DEFAULT 'Asia/Riyadh',
    tax_rate REAL NOT NULL DEFAULT 0,
    allow_negative_stock INTEGER NOT NULL DEFAULT 0,
    invoice_prefix TEXT NOT NULL DEFAULT 'INV-',
    connected_mode INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_users (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    username TEXT NOT NULL,
    pin_salt TEXT NOT NULL,
    pin_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'cashier',
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_categories (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    server_id INTEGER,
    name TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER,
    updated_at INTEGER NOT NULL,
    server_version INTEGER
  )
  ''',
  '''
  CREATE TABLE local_products (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    server_id INTEGER,
    category_local_id TEXT,
    category_server_id INTEGER,
    name TEXT NOT NULL,
    sku TEXT,
    barcode TEXT,
    item_type TEXT,
    price REAL NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    payload_json TEXT NOT NULL DEFAULT '{}',
    stock INTEGER,
    cost REAL NOT NULL DEFAULT 0,
    tax_rate REAL NOT NULL DEFAULT 0,
    track_stock INTEGER NOT NULL DEFAULT 0,
    image_path TEXT,
    created_at INTEGER,
    updated_at INTEGER NOT NULL,
    server_version INTEGER
  )
  ''',
  '''
  CREATE TABLE local_customers (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    server_id INTEGER,
    name TEXT NOT NULL,
    phone TEXT,
    email TEXT,
    notes TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER,
    updated_at INTEGER NOT NULL,
    sync_status TEXT NOT NULL DEFAULT 'synced'
  )
  ''',
  '''
  CREATE TABLE local_tables (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    server_id INTEGER,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'available',
    capacity INTEGER,
    session_server_id INTEGER,
    table_number TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER,
    updated_at INTEGER NOT NULL,
    server_version INTEGER
  )
  ''',
  '''
  CREATE TABLE local_sequences (
    store_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    next_value INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (store_id, kind)
  )
  ''',
  '''
  CREATE TABLE local_shifts (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    user_id TEXT NOT NULL,
    opened_at INTEGER NOT NULL,
    closed_at INTEGER,
    opening_cash REAL NOT NULL DEFAULT 0,
    closing_cash REAL,
    expected_cash REAL,
    actual_cash REAL,
    difference REAL,
    status TEXT NOT NULL DEFAULT 'open'
  )
  ''',
  '''
  CREATE TABLE local_cash_movements (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    shift_local_id TEXT NOT NULL,
    type TEXT NOT NULL,
    amount REAL NOT NULL,
    reason TEXT,
    reference_id TEXT,
    created_by_user_id TEXT,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_orders (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    server_id INTEGER,
    client_reference TEXT NOT NULL,
    order_number TEXT,
    order_type TEXT NOT NULL,
    table_server_id INTEGER,
    table_local_id TEXT,
    session_local_id TEXT,
    customer_local_id TEXT,
    created_by_user_id TEXT,
    notes TEXT,
    subtotal REAL NOT NULL DEFAULT 0,
    tax_amount REAL NOT NULL DEFAULT 0,
    discount_amount REAL NOT NULL DEFAULT 0,
    discount_percent REAL NOT NULL DEFAULT 0,
    total_amount REAL NOT NULL DEFAULT 0,
    pos_status TEXT NOT NULL DEFAULT 'new',
    payment_status TEXT NOT NULL DEFAULT 'unpaid',
    fulfillment_status TEXT NOT NULL DEFAULT 'unfulfilled',
    sync_status TEXT NOT NULL DEFAULT 'pending',
    last_error TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    completed_at INTEGER,
    synced_at INTEGER
  )
  ''',
  '''
  CREATE TABLE local_order_items (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    order_local_id TEXT NOT NULL,
    server_id INTEGER,
    product_server_id INTEGER,
    product_local_id TEXT,
    name TEXT NOT NULL,
    sku_snapshot TEXT,
    barcode_snapshot TEXT,
    quantity INTEGER NOT NULL,
    unit_price REAL NOT NULL,
    cost_snapshot REAL NOT NULL DEFAULT 0,
    discount_amount REAL NOT NULL DEFAULT 0,
    tax_rate REAL NOT NULL DEFAULT 0,
    tax_amount REAL NOT NULL DEFAULT 0,
    total_amount REAL NOT NULL,
    notes TEXT,
    is_removed INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER,
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_invoices (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    server_id INTEGER,
    invoice_number TEXT,
    local_invoice_number TEXT,
    server_invoice_number TEXT,
    order_local_id TEXT,
    status TEXT NOT NULL DEFAULT 'closed',
    subtotal REAL NOT NULL DEFAULT 0,
    discount_amount REAL NOT NULL DEFAULT 0,
    tax_amount REAL NOT NULL DEFAULT 0,
    total_amount REAL NOT NULL DEFAULT 0,
    created_by_user_id TEXT,
    sync_status TEXT NOT NULL DEFAULT 'pending',
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_payments (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    server_id INTEGER,
    order_local_id TEXT,
    invoice_local_id TEXT,
    method TEXT NOT NULL,
    amount REAL NOT NULL,
    tendered REAL,
    change_due REAL NOT NULL DEFAULT 0,
    shift_local_id TEXT,
    sync_status TEXT NOT NULL DEFAULT 'pending',
    client_reference TEXT NOT NULL,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_returns (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    invoice_local_id TEXT,
    order_local_id TEXT,
    reason TEXT,
    refund_amount REAL NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'completed',
    created_by_user_id TEXT,
    shift_local_id TEXT,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_return_items (
    local_id TEXT NOT NULL PRIMARY KEY,
    return_local_id TEXT NOT NULL,
    workspace_id INTEGER NOT NULL,
    order_item_local_id TEXT,
    product_local_id TEXT,
    product_name_snapshot TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    refund_amount REAL NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_stock_movements (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    product_local_id TEXT,
    product_server_id INTEGER,
    catalog_product_id INTEGER,
    kind TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    before_quantity INTEGER,
    after_quantity INTEGER,
    reference_type TEXT,
    reference_id TEXT,
    user_id TEXT,
    sync_status TEXT NOT NULL DEFAULT 'local',
    client_reference TEXT NOT NULL,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_draft_carts (
    local_id TEXT NOT NULL PRIMARY KEY,
    workspace_id INTEGER NOT NULL,
    channel TEXT NOT NULL,
    table_local_id TEXT,
    table_server_id INTEGER,
    customer_local_id TEXT,
    notes TEXT,
    discount_amount REAL NOT NULL DEFAULT 0,
    discount_percent REAL NOT NULL DEFAULT 0,
    tax_rate REAL NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_draft_cart_lines (
    local_id TEXT NOT NULL PRIMARY KEY,
    cart_local_id TEXT NOT NULL,
    workspace_id INTEGER NOT NULL,
    product_local_id TEXT NOT NULL,
    product_server_id INTEGER,
    name TEXT NOT NULL,
    sku TEXT,
    barcode TEXT,
    quantity INTEGER NOT NULL,
    unit_price REAL NOT NULL,
    cost REAL NOT NULL DEFAULT 0,
    discount_amount REAL NOT NULL DEFAULT 0,
    tax_rate REAL NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE local_settings (
    key TEXT NOT NULL,
    workspace_id INTEGER NOT NULL,
    value_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (workspace_id, key)
  )
  ''',
];
