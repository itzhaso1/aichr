import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copies a product photo into app documents so the path survives restart.
class ProductImageStore {
  ProductImageStore({Directory? documentsDirectory})
    : _documentsDirectory = documentsDirectory;

  static const relativeRoot = 'hasim_cashier/product_images';

  final Directory? _documentsDirectory;

  Future<Directory> _docs() async {
    return _documentsDirectory ?? await getApplicationDocumentsDirectory();
  }

  Future<String> persist({
    required String sourcePath,
    required int workspaceId,
    required String productLocalId,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw StateError('ملف الصورة غير موجود.');
    }
    final ext = p.extension(sourcePath).toLowerCase();
    const allowed = {'.png', '.jpg', '.jpeg', '.webp', '.gif'};
    final safeExt = allowed.contains(ext) ? ext : '.png';
    final docs = await _docs();
    final dir = Directory(p.join(docs.path, relativeRoot, '$workspaceId'));
    await dir.create(recursive: true);
    final dest = File(p.join(dir.path, '$productLocalId$safeExt'));
    if (await dest.exists()) {
      await dest.delete();
    }
    await source.copy(dest.path);
    return dest.path;
  }

  static File? fileIfExists(String? stored) {
    final path = stored?.trim();
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (file.existsSync()) return file;
    return null;
  }
}
