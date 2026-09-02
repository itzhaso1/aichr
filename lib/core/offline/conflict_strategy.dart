/// Conflict handling strategy for كاشير حاسم offline sync.
///
/// Laravel remains source of truth after sync. Daily POS is fully local-first;
/// network is optional and used only to sync queued work.
///
/// | Domain | Offline allowed | Conflict rule / Source of Truth |
/// |--------|-----------------|--------------------------------|
/// | Products / prices / categories | cache | Laravel |
/// | Users / permissions / settings | cache | Laravel |
/// | Customers | create offline | POS → Laravel (detect, no LWW) |
/// | Orders / payments / invoices | yes | POS → Laravel (detect, no LWW) |
/// | Stock | movements only | Laravel via sale/purchase/return/adjustment/transfer events |
/// | Refund / invoice_edit / admin catalog | online | Require reconnect |
///
/// On sync failure: keep local Pending/Failed record, never silent-delete.
/// On sync success with replay (same client_reference): treat as Synced.
library;

enum ConflictPolicy {
  /// Accept server representation; refresh local cache.
  serverWins,

  /// Keep local pending queue entry until explicit retry/success.
  keepLocalPending,

  /// Operation blocked offline — user must reconnect.
  requireOnline,

  /// Record both sides in sync_conflicts; do not discard either silently.
  detectAndRecord,
}

class ConflictStrategy {
  const ConflictStrategy._();

  static ConflictPolicy forDomain(String domain) => switch (domain) {
        'catalog' ||
        'inventory' ||
        'tables' ||
        'product' ||
        'category' ||
        'settings' ||
        'users' ||
        'product_availability' =>
          ConflictPolicy.serverWins,
        'stock' || 'stock_movement' => ConflictPolicy.serverWins,
        'pending_order' ||
        'order' ||
        'customer' ||
        'open_session' ||
        'close_table' ||
        'payment' ||
        'invoice' ||
        'table_session' ||
        'table_action' ||
        'transfer' ||
        'merge' ||
        'split' ||
        'discount' ||
        'note' ||
        'cancel_session' =>
          ConflictPolicy.detectAndRecord,
        'refund' || 'invoice_edit' => ConflictPolicy.requireOnline,
        _ => ConflictPolicy.serverWins,
      };
}
