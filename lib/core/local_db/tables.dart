import 'package:drift/drift.dart';

/// Local POS tables — Drift is the operational source of truth.
/// Money columns are INTEGER minor units (cents). Rates stay REAL.
/// `serverId` is nullable so Standalone works without Laravel.

class LocalDevices extends Table {
  TextColumn get deviceId => text()();
  IntColumn get accountId => integer().nullable()();
  IntColumn get workspaceId => integer().nullable()();
  IntColumn get userId => integer().nullable()();
  TextColumn get name => text().withDefault(const Constant('كاشير حاسم'))();
  TextColumn get platform => text().withDefault(const Constant('cashier'))();
  DateTimeColumn get registeredAt => dateTime().nullable()();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {deviceId};
}

class LocalCategories extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  IntColumn get serverId => integer().nullable()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get serverVersion => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalProducts extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  IntColumn get serverId => integer().nullable()();
  TextColumn get categoryLocalId => text().nullable().references(
    LocalCategories,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get categoryServerId => integer().nullable()();
  TextColumn get name => text()();
  TextColumn get sku => text().nullable()();
  TextColumn get barcode => text().nullable()();
  TextColumn get itemType => text().nullable()();
  IntColumn get price => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  IntColumn get stock => integer().nullable()();
  IntColumn get cost => integer().withDefault(const Constant(0))();
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  BoolColumn get trackStock => boolean().withDefault(const Constant(false))();
  TextColumn get imagePath => text().nullable()();
  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get serverVersion => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalTables extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  IntColumn get serverId => integer().nullable()();
  TextColumn get name => text()();
  TextColumn get status => text().withDefault(const Constant('available'))();
  IntColumn get capacity => integer().nullable()();
  IntColumn get sessionServerId => integer().nullable()();
  TextColumn get tableNumber => text().nullable()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get serverVersion => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalCustomers extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  IntColumn get serverId => integer().nullable()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalOrders extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get deviceId => text()();
  IntColumn get serverId => integer().nullable()();
  TextColumn get clientReference => text()();
  TextColumn get orderNumber => text().nullable()();
  TextColumn get orderType => text()();
  IntColumn get tableServerId => integer().nullable()();
  TextColumn get tableLocalId => text().nullable().references(
    LocalTables,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get sessionLocalId => text().nullable().references(
    LocalSessions,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get customerLocalId => text().nullable().references(
    LocalCustomers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get createdByUserId => text().nullable().references(
    LocalUsers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get notes => text().nullable()();
  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  IntColumn get taxAmount => integer().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  RealColumn get discountPercent => real().withDefault(const Constant(0))();
  IntColumn get totalAmount => integer().withDefault(const Constant(0))();
  TextColumn get posStatus => text().withDefault(const Constant('new'))();
  TextColumn get paymentStatus =>
      text().withDefault(const Constant('unpaid'))();
  TextColumn get fulfillmentStatus =>
      text().withDefault(const Constant('unfulfilled'))();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().nullable()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalOrderItems extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get orderLocalId => text().references(
    LocalOrders,
    #localId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get serverId => integer().nullable()();
  IntColumn get productServerId => integer().nullable()();
  TextColumn get productLocalId => text().nullable().references(
    LocalProducts,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get name => text()();
  TextColumn get skuSnapshot => text().nullable()();
  TextColumn get barcodeSnapshot => text().nullable()();
  IntColumn get quantity => integer()();
  IntColumn get unitPrice => integer()();
  IntColumn get costSnapshot => integer().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  IntColumn get taxAmount => integer().withDefault(const Constant(0))();
  IntColumn get totalAmount => integer()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isRemoved => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalStockMovements extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get deviceId => text()();
  TextColumn get productLocalId => text().nullable().references(
    LocalProducts,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get productServerId => integer().nullable()();
  IntColumn get catalogProductId => integer().nullable()();
  TextColumn get kind => text()();
  IntColumn get quantity => integer()();
  IntColumn get beforeQuantity => integer().nullable()();
  IntColumn get afterQuantity => integer().nullable()();
  TextColumn get referenceType => text().nullable()();
  TextColumn get referenceId => text().nullable()();
  TextColumn get userId => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('local'))();
  TextColumn get clientReference => text()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalPayments extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get deviceId => text()();
  IntColumn get serverId => integer().nullable()();
  TextColumn get orderLocalId => text().nullable().references(
    LocalOrders,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get invoiceLocalId => text().nullable().references(
    LocalInvoices,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get method => text()();
  IntColumn get amount => integer()();
  IntColumn get tendered => integer().nullable()();
  IntColumn get changeDue => integer().withDefault(const Constant(0))();
  TextColumn get shiftLocalId => text().nullable().references(
    LocalShifts,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  TextColumn get clientReference => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalInvoices extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get deviceId => text()();
  IntColumn get serverId => integer().nullable()();
  TextColumn get invoiceNumber => text().nullable()();
  TextColumn get localInvoiceNumber => text().nullable()();
  TextColumn get serverInvoiceNumber => text().nullable()();
  TextColumn get orderLocalId => text().nullable().references(
    LocalOrders,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get status => text().withDefault(const Constant('closed'))();
  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  IntColumn get taxAmount => integer().withDefault(const Constant(0))();
  IntColumn get totalAmount => integer().withDefault(const Constant(0))();
  TextColumn get createdByUserId => text().nullable().references(
    LocalUsers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalSettings extends Table {
  TextColumn get key => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get valueJson => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, key};
}

class LocalPermissions extends Table {
  TextColumn get key => text()();
  IntColumn get workspaceId => integer()();
  IntColumn get userId => integer()();
  BoolColumn get allowed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, userId, key};
}

class SyncQueueItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get workspaceId => integer()();
  TextColumn get deviceId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();
  TextColumn get payloadJson => text()();
  TextColumn get clientReference => text()();
  TextColumn get operationUuid => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
}

class SyncConflicts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get workspaceId => integer()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get strategy => text()();
  TextColumn get localJson => text()();
  TextColumn get serverJson => text()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}

class SyncMetadata extends Table {
  TextColumn get key => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get deviceId => text().nullable()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, key};
}

class LocalStores extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get name => text()();
  TextColumn get currency => text().withDefault(const Constant('SAR'))();
  TextColumn get timezone =>
      text().withDefault(const Constant('Asia/Riyadh'))();
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  BoolColumn get allowNegativeStock =>
      boolean().withDefault(const Constant(false))();
  TextColumn get invoicePrefix => text().withDefault(const Constant('INV-'))();
  BoolColumn get connectedMode =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalUsers extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get name => text()();
  TextColumn get username => text()();
  TextColumn get pinSalt => text()();
  TextColumn get pinHash => text()();
  TextColumn get role => text().withDefault(const Constant('cashier'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalSequences extends Table {
  TextColumn get storeId =>
      text().references(LocalStores, #localId, onDelete: KeyAction.restrict)();
  TextColumn get kind => text()();
  IntColumn get nextValue => integer()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {storeId, kind};
}

class LocalSessions extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get tableLocalId =>
      text().references(LocalTables, #localId, onDelete: KeyAction.restrict)();
  TextColumn get status => text().withDefault(const Constant('open'))();
  DateTimeColumn get openedAt => dateTime()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get openedByUserId => text().nullable().references(
    LocalUsers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get closedByUserId => text().nullable().references(
    LocalUsers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get notes => text().nullable()();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalDraftCarts extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get channel => text()();
  TextColumn get tableLocalId => text().nullable().references(
    LocalTables,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get tableServerId => integer().nullable()();
  TextColumn get customerLocalId => text().nullable().references(
    LocalCustomers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get notes => text().nullable()();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  RealColumn get discountPercent => real().withDefault(const Constant(0))();
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalDraftCartLines extends Table {
  TextColumn get localId => text()();
  TextColumn get cartLocalId => text().references(
    LocalDraftCarts,
    #localId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get workspaceId => integer()();
  TextColumn get productLocalId => text().references(
    LocalProducts,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  IntColumn get productServerId => integer().nullable()();
  TextColumn get name => text()();
  TextColumn get sku => text().nullable()();
  TextColumn get barcode => text().nullable()();
  IntColumn get quantity => integer()();
  IntColumn get unitPrice => integer()();
  IntColumn get cost => integer().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  RealColumn get taxRate => real().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalReturns extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get invoiceLocalId => text().nullable().references(
    LocalInvoices,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get orderLocalId => text().nullable().references(
    LocalOrders,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get reason => text().nullable()();
  IntColumn get refundAmount => integer().withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('completed'))();
  TextColumn get createdByUserId => text().nullable().references(
    LocalUsers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get shiftLocalId => text().nullable().references(
    LocalShifts,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalReturnItems extends Table {
  TextColumn get localId => text()();
  TextColumn get returnLocalId => text().references(
    LocalReturns,
    #localId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get workspaceId => integer()();
  TextColumn get orderItemLocalId => text().nullable().references(
    LocalOrderItems,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get productLocalId => text().nullable().references(
    LocalProducts,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get productNameSnapshot => text()();
  IntColumn get quantity => integer()();
  IntColumn get refundAmount => integer()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalShifts extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get userId => text().nullable().references(
    LocalUsers,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  DateTimeColumn get openedAt => dateTime()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  IntColumn get openingCash => integer().withDefault(const Constant(0))();
  IntColumn get closingCash => integer().nullable()();
  IntColumn get expectedCash => integer().nullable()();
  IntColumn get actualCash => integer().nullable()();
  IntColumn get difference => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('open'))();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}

class LocalCashMovements extends Table {
  TextColumn get localId => text()();
  IntColumn get workspaceId => integer()();
  TextColumn get shiftLocalId => text().references(
    LocalShifts,
    #localId,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get type => text()();
  IntColumn get amount => integer()();
  TextColumn get reason => text().nullable()();
  TextColumn get referenceId => text().nullable()();
  TextColumn get createdByUserId => text().nullable().references(
    LocalUsers,
    #localId,
    onDelete: KeyAction.setNull,
  )();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localId};
}
