import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/local_db/local_db_providers.dart';
import '../../core/pos/application/draft_cart_store.dart';
import '../../core/pos/application/pos_providers.dart';
import '../../core/pos/domain/pricing_service.dart';

@immutable
class CartLine {
  const CartLine({
    required this.productLocalId,
    required this.name,
    required this.unitPrice,
    required this.quantity,
    this.menuItemId,
    this.taxRate = 0,
    this.cost = 0,
    this.sku,
    this.barcode,
    this.itemDiscount = 0,
    this.note,
  });

  final String productLocalId;
  final int? menuItemId;
  final String name;
  final double unitPrice;
  final int quantity;
  final double taxRate;
  final double cost;
  final String? sku;
  final String? barcode;
  final double itemDiscount;
  final String? note;

  double get lineTotal => unitPrice * quantity;

  PricedLine toPriced() => PricedLine(
    productLocalId: productLocalId,
    productServerId: menuItemId,
    name: name,
    quantity: quantity,
    unitPrice: unitPrice,
    itemDiscount: itemDiscount,
    taxRate: taxRate,
    sku: sku,
    barcode: barcode,
    cost: cost,
  );

  CartLine copyWith({int? quantity, String? note, double? itemDiscount}) =>
      CartLine(
        productLocalId: productLocalId,
        menuItemId: menuItemId,
        name: name,
        unitPrice: unitPrice,
        quantity: quantity ?? this.quantity,
        taxRate: taxRate,
        cost: cost,
        sku: sku,
        barcode: barcode,
        itemDiscount: itemDiscount ?? this.itemDiscount,
        note: note ?? this.note,
      );
}

enum OrderChannel { table, takeaway, delivery }

extension OrderChannelLabel on OrderChannel {
  String get labelAr => switch (this) {
    OrderChannel.table => 'طاولة',
    OrderChannel.takeaway => 'خارجي',
    OrderChannel.delivery => 'توصيل',
  };
}

class CartState {
  const CartState({
    this.lines = const [],
    this.channel = OrderChannel.takeaway,
    this.tableId,
    this.tableLocalId,
    this.customerId,
    this.customerLocalId,
    this.discountAmount = 0,
    this.discountPercent = 0,
    this.notes,
    this.taxRate = 0,
  });

  final List<CartLine> lines;
  final OrderChannel channel;
  final int? tableId;
  final String? tableLocalId;
  final int? customerId;
  final String? customerLocalId;
  final double discountAmount;
  final double discountPercent;
  final String? notes;
  final double taxRate;

  PriceBreakdown get priced => const PricingService().quote(
    lines: [for (final line in lines) line.toPriced()],
    orderDiscountAmount: discountAmount,
    orderDiscountPercent: discountPercent,
    fallbackTaxRate: taxRate,
  );

  double get subtotal => priced.subtotal;
  double get taxAmount => priced.taxAmount;
  double get total => priced.total;

  CartState copyWith({
    List<CartLine>? lines,
    OrderChannel? channel,
    int? tableId,
    String? tableLocalId,
    int? customerId,
    String? customerLocalId,
    double? discountAmount,
    double? discountPercent,
    String? notes,
    double? taxRate,
    bool clearTable = false,
    bool clearCustomer = false,
  }) {
    return CartState(
      lines: lines ?? this.lines,
      channel: channel ?? this.channel,
      tableId: clearTable ? null : (tableId ?? this.tableId),
      tableLocalId: clearTable ? null : (tableLocalId ?? this.tableLocalId),
      customerId: clearCustomer ? null : (customerId ?? this.customerId),
      customerLocalId: clearCustomer
          ? null
          : (customerLocalId ?? this.customerLocalId),
      discountAmount: discountAmount ?? this.discountAmount,
      discountPercent: discountPercent ?? this.discountPercent,
      notes: notes ?? this.notes,
      taxRate: taxRate ?? this.taxRate,
    );
  }
}

class CartController extends StateNotifier<CartState> {
  CartController({this.store, this.workspaceId}) : super(const CartState()) {
    unawaited(_restore());
  }

  final DraftCartStore? store;
  final int? workspaceId;
  var _hydrated = false;

  Future<void> _restore() async {
    final s = store;
    final ws = workspaceId;
    if (s == null || ws == null) {
      _hydrated = true;
      return;
    }
    final draft = await s.load(workspaceId: ws, channel: state.channel.name);
    if (draft != null && draft.lines.isNotEmpty) {
      state = CartState(
        lines: [
          for (final line in draft.lines)
            CartLine(
              productLocalId: line.productLocalId,
              menuItemId: line.productServerId,
              name: line.name,
              unitPrice: line.unitPrice,
              quantity: line.quantity,
              taxRate: line.taxRate,
              cost: line.cost,
              sku: line.sku,
              barcode: line.barcode,
              itemDiscount: line.itemDiscount,
            ),
        ],
        channel: switch (draft.channel) {
          'table' => OrderChannel.table,
          'delivery' => OrderChannel.delivery,
          _ => OrderChannel.takeaway,
        },
        tableId: draft.tableServerId,
        tableLocalId: draft.tableLocalId,
        customerLocalId: draft.customerLocalId,
        discountAmount: draft.discountAmount,
        discountPercent: draft.discountPercent,
        notes: draft.notes,
        taxRate: draft.taxRate,
      );
    }
    _hydrated = true;
  }

  void _persist() {
    final s = store;
    final ws = workspaceId;
    if (!_hydrated || s == null || ws == null) return;
    unawaited(
      s.save(
        workspaceId: ws,
        channel: state.channel.name,
        tableLocalId: state.tableLocalId,
        tableServerId: state.tableId,
        customerLocalId: state.customerLocalId,
        notes: state.notes,
        discountAmount: state.discountAmount,
        discountPercent: state.discountPercent,
        taxRate: state.taxRate,
        lines: [for (final line in state.lines) line.toPriced()],
      ),
    );
  }

  void restore(CartState next) {
    state = next;
    _persist();
  }

  void setTaxRate(double rate) {
    state = state.copyWith(taxRate: rate);
    _persist();
  }

  void setChannel(OrderChannel channel) {
    state = state.copyWith(
      channel: channel,
      clearTable: channel != OrderChannel.table,
    );
    _persist();
  }

  void setTable(int? tableId, {String? tableLocalId}) {
    state = state.copyWith(tableId: tableId, tableLocalId: tableLocalId);
    _persist();
  }

  void setCustomer(int? customerId, {String? customerLocalId}) {
    if (customerId == null && customerLocalId == null) {
      state = state.copyWith(clearCustomer: true);
    } else {
      state = state.copyWith(
        customerId: customerId,
        customerLocalId: customerLocalId,
      );
    }
    _persist();
  }

  void addItem({
    required String productLocalId,
    required String name,
    required double unitPrice,
    int? menuItemId,
    double taxRate = 0,
    double cost = 0,
    String? sku,
    String? barcode,
  }) {
    final existingIndex = state.lines.indexWhere(
      (line) => line.productLocalId == productLocalId,
    );
    if (existingIndex >= 0) {
      final lines = [...state.lines];
      final current = lines[existingIndex];
      lines[existingIndex] = current.copyWith(quantity: current.quantity + 1);
      state = state.copyWith(lines: lines);
      _persist();
      return;
    }
    state = state.copyWith(
      lines: [
        ...state.lines,
        CartLine(
          productLocalId: productLocalId,
          menuItemId: menuItemId,
          name: name,
          unitPrice: unitPrice,
          quantity: 1,
          taxRate: taxRate,
          cost: cost,
          sku: sku,
          barcode: barcode,
        ),
      ],
    );
    _persist();
  }

  void setQuantity(String productLocalId, int quantity) {
    if (quantity <= 0) {
      removeItem(productLocalId);
      return;
    }
    final lines = state.lines
        .map(
          (line) => line.productLocalId == productLocalId
              ? line.copyWith(quantity: quantity)
              : line,
        )
        .toList();
    state = state.copyWith(lines: lines);
    _persist();
  }

  void removeItem(String productLocalId) {
    state = state.copyWith(
      lines: state.lines
          .where((line) => line.productLocalId != productLocalId)
          .toList(),
    );
    _persist();
  }

  void setDiscount(double amount) {
    state = state.copyWith(discountAmount: amount.clamp(0, double.infinity));
    _persist();
  }

  void setDiscountPercent(double percent) {
    state = state.copyWith(discountPercent: percent.clamp(0, 100));
    _persist();
  }

  void setNotes(String? notes) {
    state = state.copyWith(notes: notes);
    _persist();
  }

  void clear() {
    final tax = state.taxRate;
    final channel = state.channel;
    final tableLocalId = state.tableLocalId;
    state = CartState(taxRate: tax, channel: channel);
    final s = store;
    final ws = workspaceId;
    if (s != null && ws != null) {
      unawaited(
        s.clear(
          workspaceId: ws,
          channel: channel.name,
          tableLocalId: tableLocalId,
        ),
      );
    }
  }

  Map<String, dynamic> toOrderPayload({required String clientReference}) {
    return {
      'order_type': switch (state.channel) {
        OrderChannel.table => 'table',
        OrderChannel.takeaway => 'takeaway',
        OrderChannel.delivery => 'delivery',
      },
      if (state.channel == OrderChannel.table && state.tableId != null)
        'dining_table_id': state.tableId,
      if (state.customerId != null) 'customer_id': state.customerId,
      'discount_amount': state.discountAmount,
      'discount_percent': state.discountPercent,
      if (state.notes != null && state.notes!.isNotEmpty) 'notes': state.notes,
      'client_reference': clientReference,
      'items': state.lines
          .map(
            (line) => {
              'pos_menu_item_id': line.menuItemId,
              'product_local_id': line.productLocalId,
              'quantity': line.quantity,
            },
          )
          .toList(),
    };
  }
}

final cartControllerProvider = StateNotifierProvider<CartController, CartState>(
  (ref) {
    return CartController(
      store: ref.watch(draftCartStoreProvider),
      workspaceId: ref.watch(workspaceIdProvider),
    );
  },
);

final catalogItemsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final workspaceId = ref.watch(workspaceIdProvider);
  if (workspaceId == null || workspaceId <= 0) return const [];
  final catalog = ref.read(catalogRepositoryProvider);
  return catalog.products(workspaceId);
});

final categoriesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final workspaceId = ref.watch(workspaceIdProvider);
  if (workspaceId == null || workspaceId <= 0) return const [];
  final catalog = ref.read(catalogRepositoryProvider);
  return catalog.categories(workspaceId);
});
