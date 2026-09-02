/// Domain errors for Core POS. UI maps [messageAr].
class PosException implements Exception {
  const PosException(this.code, this.messageAr);

  final String code;
  final String messageAr;

  @override
  String toString() => messageAr;
}

class InsufficientStock extends PosException {
  InsufficientStock(String productName)
    : super('InsufficientStock', 'المخزون غير كافٍ للصنف: $productName');
}

class PaymentMismatch extends PosException {
  const PaymentMismatch()
    : super('PaymentMismatch', 'المبالغ المدفوعة لا تغطي إجمالي الفاتورة.');
}

class InvalidDiscount extends PosException {
  const InvalidDiscount() : super('InvalidDiscount', 'قيمة الخصم غير صالحة.');
}

class InvalidReturnQuantity extends PosException {
  const InvalidReturnQuantity()
    : super('InvalidReturnQuantity', 'كمية المرتجع غير صالحة.');
}

class ShiftNotOpen extends PosException {
  const ShiftNotOpen()
    : super('ShiftNotOpen', 'لا توجد وردية مفتوحة. افتح وردية أولاً.');
}

class InvoiceAlreadyPaid extends PosException {
  const InvoiceAlreadyPaid()
    : super('InvoiceAlreadyPaid', 'الفاتورة مدفوعة مسبقاً.');
}

class PrinterFailure extends PosException {
  const PrinterFailure(String detail) : super('PrinterFailure', detail);
}

class DatabaseFailure extends PosException {
  const DatabaseFailure(String detail)
    : super('DatabaseFailure', 'تعذر حفظ العملية محلياً: $detail');
}

class SyncFailure extends PosException {
  const SyncFailure(String detail)
    : super('SyncFailure', 'فشلت المزامنة: $detail');
}

class InvalidPin extends PosException {
  const InvalidPin() : super('InvalidPin', 'رمز PIN غير صحيح.');
}

class StoreNotFound extends PosException {
  const StoreNotFound()
    : super('StoreNotFound', 'لم يتم إعداد المتجر المحلي بعد.');
}

class UserInactive extends PosException {
  const UserInactive() : super('UserInactive', 'هذا المستخدم غير نشط.');
}

class EmptyCart extends PosException {
  const EmptyCart() : super('EmptyCart', 'السلة فارغة.');
}

class Forbidden extends PosException {
  const Forbidden()
    : super('Forbidden', 'ليست لديك صلاحية لتنفيذ هذه العملية.');
}
