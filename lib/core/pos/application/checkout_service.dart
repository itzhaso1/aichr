import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../../local_db/workspace_scope.dart';
import '../../repositories/sync_queue_repository.dart';
import '../domain/pricing_service.dart';
import '../pos_errors.dart';
import '../pos_permissions.dart';
import 'document_numbers.dart';
import 'draft_cart_store.dart';
import 'stock_engine.dart';

enum CheckoutFaultPoint {
  none,
  afterOrder,
  afterInvoice,
  afterPayment,
  afterStock,
  afterCash,
}

class PaymentTender {
  const PaymentTender({
    required this.method,
    required this.amount,
    this.tendered,
  });

  final String method;
  final double amount;
  final double? tendered;
}

class CheckoutCommand {
  const CheckoutCommand({
    required this.workspaceId,
    required this.deviceId,
    required this.storeId,
    required this.clientReference,
    required this.orderType,
    required this.lines,
    required this.payments,
    this.tableLocalId,
    this.tableServerId,
    this.sessionLocalId,
    this.customerLocalId,
    this.notes,
    this.orderDiscountAmount = 0,
    this.orderDiscountPercent = 0,
    this.taxRate = 0,
    this.createdByUserId,
    this.shiftLocalId,
    this.allowNegativeStock = false,
    this.connected = false,
    this.invoicePrefix = 'INV-',
    this.permissions = const {},
    this.clearDraftChannel,
    this.clearDraftTableLocalId,
  });

  final int workspaceId;
  final String deviceId;
  final String storeId;
  final String clientReference;
  final String orderType;
  final List<PricedLine> lines;
  final List<PaymentTender> payments;
  final String? tableLocalId;
  final int? tableServerId;
  final String? sessionLocalId;
  final String? customerLocalId;
  final String? notes;
  final double orderDiscountAmount;
  final double orderDiscountPercent;
  final double taxRate;
  final String? createdByUserId;
  final String? shiftLocalId;
  final bool allowNegativeStock;
  final bool connected;
  final String invoicePrefix;
  final Map<String, dynamic> permissions;
  final String? clearDraftChannel;
  final String? clearDraftTableLocalId;
}

class CheckoutResult {
  const CheckoutResult({
    required this.orderLocalId,
    required this.invoiceLocalId,
    required this.invoiceNumber,
    required this.total,
    required this.changeDue,
  });

  final String orderLocalId;
  final String invoiceLocalId;
  final String invoiceNumber;
  final double total;
  final double changeDue;
}

/// Completes a sale in one SQLite transaction. Never calls the network.
class CheckoutService {
  CheckoutService(
    this._db,
    this._stock,
    this._numbers,
    this._queue, {
    this.pricing = const PricingService(),
    String Function()? newId,
    this.faultForTest = CheckoutFaultPoint.none,
  }) : _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase _db;
  final StockEngine _stock;
  final DocumentNumberService _numbers;
  final SyncQueueRepository _queue;
  final PricingService pricing;
  final String Function() _newId;
  final CheckoutFaultPoint faultForTest;

  Future<CheckoutResult> execute(CheckoutCommand cmd) {
    if (cmd.lines.isEmpty) {
      throw const EmptyCart();
    }
    PosPermissions.require(cmd.permissions, PosPermissions.pay);
    if (cmd.orderDiscountAmount > 0 || cmd.orderDiscountPercent > 0) {
      PosPermissions.require(cmd.permissions, PosPermissions.discount);
    }
    for (final line in cmd.lines) {
      if (line.itemDiscount > 0) {
        PosPermissions.require(cmd.permissions, PosPermissions.discount);
        break;
      }
    }
    return _db.transaction(() async {
      await _db.writeMeta(
        cmd.workspaceId,
        'checkout_lock',
        DateTime.now().toIso8601String(),
        deviceId: cmd.deviceId,
      );

      final existing = await _paidOrder(cmd);
      if (existing != null) return existing;

      if (cmd.shiftLocalId == null || cmd.shiftLocalId!.isEmpty) {
        throw const ShiftNotOpen();
      }
      final shift =
          await (_db.select(_db.localShifts)..where(
                (t) =>
                    t.localId.equals(cmd.shiftLocalId!) &
                    t.workspaceId.equals(cmd.workspaceId),
              ))
              .getSingleOrNull();
      if (shift == null || shift.status != 'open') {
        throw const ShiftNotOpen();
      }

      final quote = pricing.quote(
        lines: cmd.lines,
        orderDiscountAmount: cmd.orderDiscountAmount,
        orderDiscountPercent: cmd.orderDiscountPercent,
        fallbackTaxRate: cmd.taxRate,
      );

      var paidCents = 0;
      var changeDueCents = 0;
      var hasCredit = false;
      for (final p in cmd.payments) {
        if (p.amount < 0) throw const PaymentMismatch();
        if (p.method == 'credit') hasCredit = true;
        paidCents += Money.toCents(p.amount);
        if (p.method == 'cash' && p.tendered != null) {
          if (Money.toCents(p.tendered!) < Money.toCents(p.amount)) {
            throw const PaymentMismatch();
          }
          changeDueCents +=
              Money.toCents(p.tendered!) - Money.toCents(p.amount);
        }
      }
      if (!hasCredit && paidCents < quote.totalCents) {
        throw const PaymentMismatch();
      }

      final now = DateTime.now();
      final orderId = cmd.clientReference;
      final invoiceId = _newId();
      final orderNumber = await _numbers.nextOrderNumber(storeId: cmd.storeId);
      final invoiceNumber = await _numbers.nextInvoiceNumber(
        storeId: cmd.storeId,
        prefix: cmd.invoicePrefix,
      );

      await _db
          .into(_db.localOrders)
          .insert(
            LocalOrdersCompanion.insert(
              localId: orderId,
              workspaceId: cmd.workspaceId,
              deviceId: cmd.deviceId,
              clientReference: cmd.clientReference,
              orderNumber: Value(orderNumber),
              orderType: cmd.orderType,
              tableServerId: Value(cmd.tableServerId),
              tableLocalId: Value(cmd.tableLocalId),
              sessionLocalId: Value(cmd.sessionLocalId),
              customerLocalId: Value(cmd.customerLocalId),
              createdByUserId: Value(cmd.createdByUserId),
              notes: Value(cmd.notes),
              subtotal: Value(quote.subtotalCents),
              taxAmount: Value(quote.taxCents),
              discountAmount: Value(
                Money.toCents(quote.itemDiscountTotal) +
                    Money.toCents(quote.orderDiscount),
              ),
              discountPercent: Value(cmd.orderDiscountPercent),
              totalAmount: Value(quote.totalCents),
              posStatus: const Value('new'),
              paymentStatus: const Value('paid'),
              fulfillmentStatus: const Value('unfulfilled'),
              syncStatus: Value(cmd.connected ? 'pending' : 'local'),
              createdAt: now,
              updatedAt: now,
              completedAt: Value(now),
            ),
          );
      await _fault(CheckoutFaultPoint.afterOrder);

      for (final line in quote.lineResults) {
        await _db
            .into(_db.localOrderItems)
            .insert(
              LocalOrderItemsCompanion.insert(
                localId: _newId(),
                workspaceId: cmd.workspaceId,
                orderLocalId: orderId,
                productServerId: Value(line.line.productServerId),
                productLocalId: Value(line.line.productLocalId),
                name: line.line.name,
                skuSnapshot: Value(line.line.sku),
                barcodeSnapshot: Value(line.line.barcode),
                quantity: line.line.quantity,
                unitPrice: line.line.unitPriceCents,
                costSnapshot: Value(Money.toCents(line.line.cost)),
                discountAmount: Value(line.discountCents),
                taxRate: Value(
                  line.line.taxRate > 0 ? line.line.taxRate : cmd.taxRate,
                ),
                taxAmount: Value(line.taxCents),
                totalAmount: line.totalCents,
                createdAt: Value(now),
                updatedAt: now,
              ),
            );
        await _stock.apply(
          workspaceId: cmd.workspaceId,
          productLocalId: line.line.productLocalId,
          type: 'sale',
          quantity: line.line.quantity,
          allowNegative: cmd.allowNegativeStock,
          referenceType: 'order',
          referenceId: orderId,
          userId: cmd.createdByUserId,
          deviceId: cmd.deviceId,
        );
        await _fault(CheckoutFaultPoint.afterStock);
      }

      final invoicePayload = {
        'local_id': invoiceId,
        'invoice_number': invoiceNumber,
        'order_local_id': orderId,
        'subtotal': quote.subtotal,
        'discount_amount': Money.fromCents(
          Money.toCents(quote.itemDiscountTotal) +
              Money.toCents(quote.orderDiscount),
        ),
        'tax_amount': quote.taxAmount,
        'total_amount': quote.total,
        'payment_method': cmd.payments.map((p) => p.method).join('+'),
        'closed_at': now.toUtc().toIso8601String(),
        'items': [
          for (final line in quote.lineResults)
            {
              'item_name': line.line.name,
              'quantity': line.line.quantity,
              'unit_price': line.line.unitPrice,
              'tax_amount': line.taxAmount,
              'total_amount': line.total,
            },
        ],
      };

      await _db
          .into(_db.localInvoices)
          .insert(
            LocalInvoicesCompanion.insert(
              localId: invoiceId,
              workspaceId: cmd.workspaceId,
              deviceId: cmd.deviceId,
              invoiceNumber: Value(invoiceNumber),
              localInvoiceNumber: Value(invoiceNumber),
              orderLocalId: Value(orderId),
              status: const Value('closed'),
              subtotal: Value(quote.subtotalCents),
              discountAmount: Value(
                Money.toCents(quote.itemDiscountTotal) +
                    Money.toCents(quote.orderDiscount),
              ),
              taxAmount: Value(quote.taxCents),
              totalAmount: Value(quote.totalCents),
              createdByUserId: Value(cmd.createdByUserId),
              syncStatus: Value(cmd.connected ? 'pending' : 'local'),
              payloadJson: Value(jsonEncode(invoicePayload)),
              createdAt: now,
            ),
          );
      await _fault(CheckoutFaultPoint.afterInvoice);

      for (final p in cmd.payments) {
        await _db
            .into(_db.localPayments)
            .insert(
              LocalPaymentsCompanion.insert(
                localId: _newId(),
                workspaceId: cmd.workspaceId,
                deviceId: cmd.deviceId,
                orderLocalId: Value(orderId),
                invoiceLocalId: Value(invoiceId),
                method: p.method,
                amount: Money.toCents(p.amount),
                tendered: Value(
                  p.tendered == null ? null : Money.toCents(p.tendered!),
                ),
                changeDue: Value(
                  p.method == 'cash' && p.tendered != null
                      ? Money.toCents(p.tendered!) - Money.toCents(p.amount)
                      : 0,
                ),
                shiftLocalId: Value(cmd.shiftLocalId),
                syncStatus: Value(cmd.connected ? 'pending' : 'local'),
                clientReference: '${cmd.clientReference}:${p.method}',
                createdAt: now,
              ),
            );
        await _fault(CheckoutFaultPoint.afterPayment);
        if (p.method == 'cash') {
          await _db
              .into(_db.localCashMovements)
              .insert(
                LocalCashMovementsCompanion.insert(
                  localId: _newId(),
                  workspaceId: cmd.workspaceId,
                  shiftLocalId: cmd.shiftLocalId!,
                  type: 'sale',
                  amount: Money.toCents(p.amount),
                  reason: const Value('بيع نقدي'),
                  referenceId: Value(invoiceId),
                  createdByUserId: Value(cmd.createdByUserId),
                  createdAt: now,
                ),
              );
          await _fault(CheckoutFaultPoint.afterCash);
        }
      }

      if (cmd.connected) {
        await _queue.enqueue(
          workspaceId: cmd.workspaceId,
          deviceId: cmd.deviceId,
          entityType: 'order',
          entityId: orderId,
          operation: 'create',
          payload: {
            'client_reference': cmd.clientReference,
            'order_type': cmd.orderType,
            if (cmd.tableServerId != null) 'dining_table_id': cmd.tableServerId,
            'items': [
              for (final line in cmd.lines)
                {
                  'pos_menu_item_id': line.productServerId,
                  'quantity': line.quantity,
                },
            ],
          },
          clientReference: cmd.clientReference,
        );
      }

      if (cmd.clearDraftChannel != null) {
        await DraftCartStore(_db).clear(
          workspaceId: cmd.workspaceId,
          channel: cmd.clearDraftChannel!,
          tableLocalId: cmd.clearDraftTableLocalId,
        );
      }

      return CheckoutResult(
        orderLocalId: orderId,
        invoiceLocalId: invoiceId,
        invoiceNumber: invoiceNumber,
        total: quote.total,
        changeDue: Money.fromCents(changeDueCents),
      );
    });
  }

  Future<CheckoutResult?> _paidOrder(CheckoutCommand cmd) async {
    final existing =
        await (_db.select(_db.localOrders)..where(
              (t) =>
                  t.workspaceId.equals(cmd.workspaceId) &
                  t.clientReference.equals(cmd.clientReference),
            ))
            .getSingleOrNull();
    if (existing == null || existing.paymentStatus != 'paid') return null;
    final invoice =
        await (_db.select(_db.localInvoices)..where(
              (t) =>
                  t.workspaceId.equals(cmd.workspaceId) &
                  t.orderLocalId.equals(existing.localId),
            ))
            .getSingleOrNull();
    return CheckoutResult(
      orderLocalId: existing.localId,
      invoiceLocalId: invoice?.localId ?? existing.localId,
      invoiceNumber:
          invoice?.localInvoiceNumber ??
          invoice?.invoiceNumber ??
          existing.orderNumber ??
          existing.localId,
      total: Money.fromCents(existing.totalAmount),
      changeDue: 0,
    );
  }

  Future<void> _fault(CheckoutFaultPoint point) async {
    if (faultForTest == point) {
      throw DatabaseFailure('injected:$point');
    }
  }
}
