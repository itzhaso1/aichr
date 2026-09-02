enum SyncStatus { pending, syncing, synced, failed }

/// Local table/takeaway order waiting for Laravel confirmation.
///
/// [localId] == [idempotencyKey] == `client_reference` and never changes
/// across retries so a lost HTTP response cannot create a second server order.
class PendingOrder {
  const PendingOrder({
    required this.localId,
    required this.idempotencyKey,
    required this.workspaceId,
    required this.tableId,
    required this.orderType,
    required this.items,
    required this.createdAt,
    this.notes,
    this.status = SyncStatus.pending,
    this.retryCount = 0,
    this.lastError,
    this.serverOrderId,
  });

  final String localId;
  final String idempotencyKey;
  final int? workspaceId;
  final int? tableId;
  final String orderType;
  final List<Map<String, dynamic>> items;
  final String? notes;
  final DateTime createdAt;
  final SyncStatus status;
  final int retryCount;
  final String? lastError;
  final int? serverOrderId;

  bool get isUnsynced =>
      status == SyncStatus.pending ||
      status == SyncStatus.syncing ||
      status == SyncStatus.failed;

  bool get isTableOrder =>
      orderType == 'table' && tableId != null && tableId! > 0;

  String get statusLabel => switch (status) {
        SyncStatus.pending => 'بانتظار المزامنة',
        SyncStatus.syncing => 'جاري المزامنة',
        SyncStatus.failed => 'فشلت المزامنة',
        SyncStatus.synced => 'تمت المزامنة',
      };

  double get subtotal => items.fold<double>(0, (sum, item) {
        final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
        final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
        final total = (item['total_amount'] as num?)?.toDouble();
        return sum + (total ?? qty * price);
      });

  Map<String, dynamic> toApiPayload() {
    return {
      'order_type': orderType,
      if (tableId != null) 'dining_table_id': tableId,
      'client_reference': idempotencyKey,
      if (notes != null && notes!.trim().isNotEmpty) 'notes': notes!.trim(),
      'items': [
        for (final item in items)
          {
            'pos_menu_item_id': item['pos_menu_item_id'],
            'quantity': item['quantity'],
          },
      ],
    };
  }

  /// Shape compatible with TableDetailScreen order cards.
  Map<String, dynamic> toDisplayOrder() {
    return {
      'id': serverOrderId ?? localId,
      'local_id': localId,
      'is_local_pending': isUnsynced,
      'order_number': serverOrderId != null ? '$serverOrderId' : 'محلي',
      'pos_status': 'new',
      'payment_status': 'unpaid',
      'sync_status': status.name,
      'sync_label': statusLabel,
      'last_error': lastError,
      'notes': notes,
      'discount_amount': 0,
      'tax_amount': 0,
      'total_amount': subtotal,
      'subtotal': subtotal,
      'client_reference': idempotencyKey,
      'dining_table_id': tableId,
      'items': [
        for (final item in items)
          {
            'id': item['id'],
            'pos_menu_item_id': item['pos_menu_item_id'],
            'product_name': item['name'] ?? item['product_name'] ?? 'صنف',
            'variant_name': item['variant_name'],
            'quantity': item['quantity'],
            'unit_price': item['unit_price'] ?? 0,
            'discount_amount': item['discount_amount'] ?? 0,
            'total_amount': item['total_amount'] ??
                ((item['quantity'] as num?) ?? 0) *
                    ((item['unit_price'] as num?) ?? 0),
          },
      ],
    };
  }

  Map<String, dynamic> toRecord() => {
        'local_id': localId,
        'idempotency_key': idempotencyKey,
        'client_reference': idempotencyKey,
        'workspace_id': workspaceId,
        'table_id': tableId,
        'order_type': orderType,
        'items': items,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'status': status.name,
        'attempts': retryCount,
        'retry_count': retryCount,
        'last_error': lastError,
        'server_order_id': serverOrderId,
        'payload': toApiPayload(),
      };

  static PendingOrder fromRecord(Map<String, dynamic> raw) {
    final payload = raw['payload'] is Map
        ? Map<String, dynamic>.from(raw['payload'] as Map)
        : raw;
    final key = '${raw['idempotency_key'] ?? raw['client_reference'] ?? raw['local_id']}';
    final localId = '${raw['local_id'] ?? key}';
    final items = _itemsFrom(raw['items'] ?? payload['items']);
    final tableId = (raw['table_id'] as num?)?.toInt() ??
        (payload['dining_table_id'] as num?)?.toInt();
    final statusName = '${raw['status'] ?? SyncStatus.pending.name}';
    final status = SyncStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => SyncStatus.pending,
    );
    return PendingOrder(
      localId: localId,
      idempotencyKey: key.isEmpty ? localId : key,
      workspaceId: (raw['workspace_id'] as num?)?.toInt(),
      tableId: tableId,
      orderType: '${raw['order_type'] ?? payload['order_type'] ?? 'table'}',
      items: items,
      notes: raw['notes'] as String? ?? payload['notes'] as String?,
      createdAt: DateTime.tryParse('${raw['created_at'] ?? ''}') ??
          DateTime.now(),
      status: status,
      retryCount: (raw['retry_count'] as num?)?.toInt() ??
          (raw['attempts'] as num?)?.toInt() ??
          0,
      lastError: raw['last_error'] as String?,
      serverOrderId: (raw['server_order_id'] as num?)?.toInt(),
    );
  }

  static List<Map<String, dynamic>> _itemsFrom(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  PendingOrder copyWith({
    List<Map<String, dynamic>>? items,
    String? notes,
    SyncStatus? status,
    int? retryCount,
    String? lastError,
    int? serverOrderId,
    bool clearError = false,
  }) {
    return PendingOrder(
      localId: localId,
      idempotencyKey: idempotencyKey,
      workspaceId: workspaceId,
      tableId: tableId,
      orderType: orderType,
      items: items ?? this.items,
      notes: notes ?? this.notes,
      createdAt: createdAt,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: clearError ? null : (lastError ?? this.lastError),
      serverOrderId: serverOrderId ?? this.serverOrderId,
    );
  }
}

/// How a POST /orders failure should be recorded. Never mark synced on 401.
enum SyncOutcome {
  markSynced,
  keepPending,
  markFailed,
  stopAuth,
}

class SyncPolicy {
  const SyncPolicy._();

  static SyncOutcome fromStatusCode(int? statusCode, {required bool success}) {
    if (success) return SyncOutcome.markSynced;
    if (statusCode == 401) return SyncOutcome.stopAuth;
    if (statusCode == 403 || statusCode == 422) return SyncOutcome.markFailed;
    return SyncOutcome.keepPending;
  }

  static bool shouldAutoSync(SyncStatus status) =>
      status == SyncStatus.pending || status == SyncStatus.syncing;
}

class SyncFlushResult {
  const SyncFlushResult({
    this.synced = 0,
    this.failed = 0,
    this.keptPending = 0,
    this.authRequired = false,
    this.skippedInFlight = false,
  });

  final int synced;
  final int failed;
  final int keptPending;
  final bool authRequired;
  final bool skippedInFlight;
}
