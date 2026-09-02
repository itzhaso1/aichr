import '../pos_errors.dart';

/// Single money policy: integer minor units (cents) in domain and SQLite.
///
/// `10.50` persists as `1050`. UI/API boundaries convert with [toCents] /
/// [fromCents]. Never add `double` prices inside business logic.
class Money {
  const Money._();

  static int toCents(num value) => (value * 100).round();

  static double fromCents(int cents) => cents / 100.0;

  static double round(num value) => fromCents(toCents(value));

  static int add(int a, int b) => a + b;

  static int percentOf(int cents, num percent) =>
      toCents(fromCents(cents) * (percent / 100));
}

class PricedLine {
  const PricedLine({
    required this.productLocalId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.itemDiscount = 0,
    this.taxRate = 0,
    this.sku,
    this.barcode,
    this.cost = 0,
    this.productServerId,
  });

  final String productLocalId;
  final int? productServerId;
  final String name;
  final int quantity;
  final double unitPrice;
  final double itemDiscount;
  final double taxRate;
  final String? sku;
  final String? barcode;
  final double cost;

  int get unitPriceCents => Money.toCents(unitPrice);

  int get lineSubtotalCents => unitPriceCents * quantity;

  double get lineSubtotal => Money.fromCents(lineSubtotalCents);
}

class PriceBreakdown {
  const PriceBreakdown({
    required this.lines,
    required this.subtotal,
    required this.itemDiscountTotal,
    required this.orderDiscount,
    required this.taxAmount,
    required this.total,
    required this.lineResults,
    required this.subtotalCents,
    required this.taxCents,
    required this.totalCents,
  });

  final List<PricedLine> lines;
  final double subtotal;
  final double itemDiscountTotal;
  final double orderDiscount;
  final double taxAmount;
  final double total;
  final List<PricedLineResult> lineResults;
  final int subtotalCents;
  final int taxCents;
  final int totalCents;
}

class PricedLineResult {
  const PricedLineResult({
    required this.line,
    required this.lineSubtotal,
    required this.discountAmount,
    required this.taxAmount,
    required this.total,
    required this.lineSubtotalCents,
    required this.discountCents,
    required this.taxCents,
    required this.totalCents,
  });

  final PricedLine line;
  final double lineSubtotal;
  final double discountAmount;
  final double taxAmount;
  final double total;
  final int lineSubtotalCents;
  final int discountCents;
  final int taxCents;
  final int totalCents;
}

class PricingService {
  const PricingService();

  PriceBreakdown quote({
    required List<PricedLine> lines,
    double orderDiscountAmount = 0,
    double orderDiscountPercent = 0,
    double fallbackTaxRate = 0,
  }) {
    if (lines.isEmpty) {
      return const PriceBreakdown(
        lines: [],
        subtotal: 0,
        itemDiscountTotal: 0,
        orderDiscount: 0,
        taxAmount: 0,
        total: 0,
        lineResults: [],
        subtotalCents: 0,
        taxCents: 0,
        totalCents: 0,
      );
    }
    for (final line in lines) {
      if (line.quantity <= 0) {
        throw const InvalidDiscount();
      }
      if (line.unitPrice < 0 || line.itemDiscount < 0) {
        throw const InvalidDiscount();
      }
      if (Money.toCents(line.itemDiscount) > line.lineSubtotalCents) {
        throw const InvalidDiscount();
      }
    }

    var subtotalCents = 0;
    var itemDiscountCents = 0;
    for (final line in lines) {
      subtotalCents += line.lineSubtotalCents;
      itemDiscountCents += Money.toCents(line.itemDiscount);
    }
    final afterItemsCents = subtotalCents - itemDiscountCents;
    var orderDiscountCents = 0;
    if (orderDiscountPercent > 0) {
      if (orderDiscountPercent > 100) throw const InvalidDiscount();
      orderDiscountCents += Money.percentOf(afterItemsCents, orderDiscountPercent);
    }
    if (orderDiscountAmount > 0) {
      orderDiscountCents += Money.toCents(orderDiscountAmount);
    }
    if (orderDiscountCents > afterItemsCents) throw const InvalidDiscount();

    final taxableCents = afterItemsCents - orderDiscountCents;
    final results = <PricedLineResult>[];
    var taxTotalCents = 0;
    final weightBase = afterItemsCents <= 0 ? 1 : afterItemsCents;

    for (final line in lines) {
      final lineNetCents =
          line.lineSubtotalCents - Money.toCents(line.itemDiscount);
      final lineOrderDiscountCents =
          ((orderDiscountCents * lineNetCents) / weightBase).round();
      final lineTaxableCents = lineNetCents - lineOrderDiscountCents;
      final rate = line.taxRate > 0 ? line.taxRate : fallbackTaxRate;
      if (rate < 0 || rate > 100) throw const InvalidDiscount();
      final lineTaxCents = Money.percentOf(lineTaxableCents, rate);
      taxTotalCents += lineTaxCents;
      final lineTotalCents = lineTaxableCents + lineTaxCents;
      final discountCents =
          Money.toCents(line.itemDiscount) + lineOrderDiscountCents;
      results.add(
        PricedLineResult(
          line: line,
          lineSubtotal: line.lineSubtotal,
          discountAmount: Money.fromCents(discountCents),
          taxAmount: Money.fromCents(lineTaxCents),
          total: Money.fromCents(lineTotalCents),
          lineSubtotalCents: line.lineSubtotalCents,
          discountCents: discountCents,
          taxCents: lineTaxCents,
          totalCents: lineTotalCents,
        ),
      );
    }

    final totalCents = taxableCents + taxTotalCents;
    if (totalCents < 0) throw const InvalidDiscount();

    return PriceBreakdown(
      lines: lines,
      subtotal: Money.fromCents(subtotalCents),
      itemDiscountTotal: Money.fromCents(itemDiscountCents),
      orderDiscount: Money.fromCents(orderDiscountCents),
      taxAmount: Money.fromCents(taxTotalCents),
      total: Money.fromCents(totalCents),
      lineResults: results,
      subtotalCents: subtotalCents,
      taxCents: taxTotalCents,
      totalCents: totalCents,
    );
  }
}
