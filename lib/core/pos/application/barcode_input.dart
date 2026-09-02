import 'catalog_admin_service.dart';

/// Hardware scanners that emulate a keyboard (USB/Bluetooth HID).
/// Camera scanning is a later optional dependency — not required for Core POS.
class BarcodeInput {
  BarcodeInput(this._catalog);

  final CatalogAdminService _catalog;

  Future<Map<String, dynamic>?> lookup({
    required int workspaceId,
    required String raw,
  }) {
    return _catalog.findByBarcode(workspaceId: workspaceId, barcode: raw);
  }
}
