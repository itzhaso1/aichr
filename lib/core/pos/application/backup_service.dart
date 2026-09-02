import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../local_db/app_database.dart';
import '../pos_errors.dart';
import '../pos_permissions.dart';
import 'backup_crypto.dart';

const backupFormatVersion = 3;
const checksumBackupFormatVersion = 2;
const legacyBackupFormatVersion = 1;

const _restoreDeleteOrder = [
  'local_cash_movements',
  'local_return_items',
  'local_returns',
  'local_payments',
  'local_order_items',
  'local_invoices',
  'local_orders',
  'local_stock_movements',
  'local_sessions',
  'local_draft_cart_lines',
  'local_draft_carts',
  'local_shifts',
  'local_customers',
  'local_products',
  'local_categories',
  'local_tables',
  'local_users',
  'local_settings',
];

const _restoreInsertOrder = [
  'local_stores',
  'local_users',
  'local_categories',
  'local_tables',
  'local_customers',
  'local_settings',
  'local_sequences',
  'local_products',
  'local_shifts',
  'local_sessions',
  'local_draft_carts',
  'local_orders',
  'local_order_items',
  'local_invoices',
  'local_payments',
  'local_returns',
  'local_return_items',
  'local_stock_movements',
  'local_cash_movements',
  'local_draft_cart_lines',
];

const _moneyColumns = {
  'local_products': {'price', 'cost'},
  'local_orders': {
    'subtotal',
    'tax_amount',
    'discount_amount',
    'total_amount',
  },
  'local_order_items': {
    'unit_price',
    'cost_snapshot',
    'discount_amount',
    'tax_amount',
    'total_amount',
  },
  'local_payments': {'amount', 'tendered', 'change_due'},
  'local_invoices': {
    'subtotal',
    'discount_amount',
    'tax_amount',
    'total_amount',
  },
  'local_sessions': {'discount_amount'},
  'local_draft_carts': {'discount_amount'},
  'local_draft_cart_lines': {'unit_price', 'cost', 'discount_amount'},
  'local_returns': {'refund_amount'},
  'local_return_items': {'refund_amount'},
  'local_shifts': {
    'opening_cash',
    'closing_cash',
    'expected_cash',
    'actual_cash',
    'difference',
  },
  'local_cash_movements': {'amount'},
};

class BackupService {
  BackupService(this._db, {BackupCrypto? crypto})
    : _crypto = crypto ?? const BackupCrypto();

  final AppDatabase _db;
  final BackupCrypto _crypto;

  Future<List<File>> listBackups() async {
    final dir = await getApplicationDocumentsDirectory();
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.contains('hasim_pos_backup_') &&
                  f.path.endsWith('.json'),
            )
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> restoreFile(
    File file, {
    required bool confirmed,
    String? password,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.backup);
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) {
      throw const DatabaseFailure('ملف النسخة الاحتياطية تالف.');
    }
    await restore(
      Map<String, dynamic>.from(raw),
      confirmed: confirmed,
      password: password,
      permissions: permissions,
    );
  }

  Future<File> exportBackup({
    required int workspaceId,
    Directory? directory,
    String? password,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.backup);
    if (password == null || password.trim().length < 6) {
      throw const DatabaseFailure(
        'كلمة مرور النسخة الاحتياطية يجب أن تكون 6 أحرف على الأقل.',
      );
    }
    final inner = await _dump(workspaceId);
    final checksum = inner['checksum_sha256'] as String;
    final plaintext = jsonEncode(inner);
    final sealed = await _crypto.encrypt(
      plaintext: plaintext,
      password: password,
    );
    final envelope = {
      'format_version': backupFormatVersion,
      'workspace_id': workspaceId,
      'exported_at': inner['exported_at'],
      'cipher': BackupCrypto.cipherName,
      'kdf': BackupCrypto.kdfName,
      'kdf_iterations': BackupCrypto.kdfIterations,
      'salt_b64': sealed.saltB64,
      'nonce_b64': sealed.nonceB64,
      'ciphertext_b64': sealed.ciphertextB64,
      'checksum_sha256': checksum,
    };
    final dir = directory ?? await getApplicationDocumentsDirectory();
    final file = File(
      p.join(
        dir.path,
        'hasim_pos_backup_${workspaceId}_${DateTime.now().millisecondsSinceEpoch}.json',
      ),
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(envelope),
    );
    return file;
  }

  String _checksum(Map tables) {
    return sha256.convert(utf8.encode(jsonEncode(tables))).toString();
  }

  Future<Map<String, dynamic>> _dump(int workspaceId) async {
    Future<List<Map<String, Object?>>> rows(TableInfo table) async {
      final result = await _db
          .customSelect(
            'SELECT * FROM ${table.actualTableName} WHERE workspace_id = ?',
            variables: [Variable.withInt(workspaceId)],
          )
          .get();
      return [for (final r in result) r.data];
    }

    final stores = await rows(_db.localStores);
    final storeIds = <String>{
      for (final row in stores)
        if (row['local_id'] != null) '${row['local_id']}',
    };
    final sequenceRows = await _db.customSelect(
      'SELECT * FROM local_sequences',
    ).get();
    final sequences = [
      for (final row in sequenceRows)
        if (storeIds.contains('${row.data['store_id']}')) row.data,
    ];

    final tables = {
      'local_stores': stores,
      'local_users': await rows(_db.localUsers),
      'local_categories': await rows(_db.localCategories),
      'local_products': await rows(_db.localProducts),
      'local_customers': await rows(_db.localCustomers),
      'local_tables': await rows(_db.localTables),
      'local_sessions': await rows(_db.localSessions),
      'local_orders': await rows(_db.localOrders),
      'local_order_items': await rows(_db.localOrderItems),
      'local_invoices': await rows(_db.localInvoices),
      'local_payments': await rows(_db.localPayments),
      'local_returns': await rows(_db.localReturns),
      'local_return_items': await rows(_db.localReturnItems),
      'local_stock_movements': await rows(_db.localStockMovements),
      'local_shifts': await rows(_db.localShifts),
      'local_cash_movements': await rows(_db.localCashMovements),
      'local_settings': await rows(_db.localSettings),
      'local_draft_carts': await rows(_db.localDraftCarts),
      'local_draft_cart_lines': await rows(_db.localDraftCartLines),
      'local_sequences': sequences,
    };

    return {
      'format_version': backupFormatVersion,
      'schema_version': 7,
      'money_unit': 'cents',
      'workspace_id': workspaceId,
      'exported_at': DateTime.now().toIso8601String(),
      'checksum_sha256': _checksum(tables),
      'tables': tables,
    };
  }

  /// Validates version, password, integrity, and money unit **before**
  /// any DELETE. Throws without touching current rows on failure.
  Future<({int workspaceId, Map tables})> validatePayload(
    Map<String, dynamic> payload, {
    String? password,
  }) async {
    final version = payload['format_version'];
    if (version != backupFormatVersion &&
        version != checksumBackupFormatVersion &&
        version != legacyBackupFormatVersion) {
      throw const DatabaseFailure('نسخة النسخة الاحتياطية غير مدعومة.');
    }

    Map<String, dynamic> inner;
    if (version == backupFormatVersion) {
      if (password == null || password.isEmpty) {
        throw const DatabaseFailure('كلمة مرور النسخة الاحتياطية مطلوبة.');
      }
      final salt = payload['salt_b64'];
      final nonce = payload['nonce_b64'];
      final cipher = payload['ciphertext_b64'];
      if (salt is! String || nonce is! String || cipher is! String) {
        throw const DatabaseFailure('ملف النسخة الاحتياطية تالف.');
      }
      try {
        final plaintext = await _crypto.decrypt(
          password: password,
          saltB64: salt,
          nonceB64: nonce,
          ciphertextB64: cipher,
        );
        final decoded = jsonDecode(plaintext);
        if (decoded is! Map) {
          throw const DatabaseFailure('ملف النسخة الاحتياطية تالف.');
        }
        inner = Map<String, dynamic>.from(decoded);
      } on FormatException catch (e) {
        if (e.message == 'مفتاح') {
          throw const DatabaseFailure('كلمة مرور النسخة الاحتياطية غير صحيحة.');
        }
        throw const DatabaseFailure('ملف النسخة الاحتياطية تالف.');
      }
    } else {
      inner = payload;
    }

    final workspaceId = inner['workspace_id'] ?? payload['workspace_id'];
    if (workspaceId is! int) {
      throw const DatabaseFailure('النسخة الاحتياطية تفتقد workspace_id.');
    }
    final tables = inner['tables'];
    if (tables is! Map) {
      throw const DatabaseFailure('ملف النسخة الاحتياطية تالف.');
    }
    if (version == backupFormatVersion ||
        version == checksumBackupFormatVersion) {
      final expected = inner['checksum_sha256'] ?? payload['checksum_sha256'];
      final actual = _checksum(tables);
      if (expected is! String || expected != actual) {
        throw const DatabaseFailure('مجموع التحقق للنسخة الاحتياطية غير مطابق.');
      }
    }
    if (inner['money_unit'] != 'cents') {
      _convertMajorUnitsToCents(tables);
    }
    return (workspaceId: workspaceId, tables: tables);
  }

  Future<void> restore(
    Map<String, dynamic> payload, {
    required bool confirmed,
    String? password,
    Map<String, dynamic>? permissions,
  }) async {
    PosPermissions.require(permissions, PosPermissions.backup);
    if (!confirmed) {
      throw const DatabaseFailure(
        'يجب تأكيد الاستعادة قبل الكتابة فوق البيانات.',
      );
    }
    final validated = await validatePayload(payload, password: password);
    await _applyValidated(validated.workspaceId, validated.tables);
  }

  Future<void> _applyValidated(int workspaceId, Map tables) async {
    await _db.transaction(() async {
      await _db.customStatement(
        'DELETE FROM local_sequences WHERE store_id IN '
        '(SELECT local_id FROM local_stores WHERE workspace_id = ?)',
        [workspaceId],
      );
      await _db.customStatement(
        'DELETE FROM local_stores WHERE workspace_id = ?',
        [workspaceId],
      );
      for (final name in _restoreDeleteOrder) {
        await _db.customStatement('DELETE FROM $name WHERE workspace_id = ?', [
          workspaceId,
        ]);
      }
      final dumpedStores = tables['local_stores'];
      if (dumpedStores is List) {
        for (final raw in dumpedStores) {
          if (raw is! Map) continue;
          final storeId = raw['local_id'];
          if (storeId == null) continue;
          await _db.customStatement(
            'DELETE FROM local_sequences WHERE store_id = ?',
            [storeId],
          );
        }
      }
      for (final table in _restoreInsertOrder) {
        final rows = tables[table];
        if (rows is! List) continue;
        await _insertChunked(table, rows);
      }
    });
  }

  /// Multi-row INSERT stays under SQLite's variable cap (~32k).
  Future<void> _insertChunked(String table, List rows) async {
    const maxVars = 900;
    var i = 0;
    while (i < rows.length) {
      final raw = rows[i];
      if (raw is! Map) {
        i++;
        continue;
      }
      final cols = raw.keys.map((k) => k.toString()).toList();
      if (cols.isEmpty) {
        i++;
        continue;
      }
      final sig = cols.join(',');
      final perRow = cols.length;
      final chunkSize = (maxVars / perRow).floor().clamp(1, 80);
      final batch = <Map>[raw];
      var j = i + 1;
      while (j < rows.length && batch.length < chunkSize) {
        final next = rows[j];
        if (next is! Map) break;
        if (next.keys.map((k) => k.toString()).join(',') != sig) break;
        batch.add(next);
        j++;
      }
      final placeholders = batch
          .map((_) => '(${List.filled(cols.length, '?').join(',')})')
          .join(',');
      await _db.customStatement(
        'INSERT OR REPLACE INTO $table (${cols.join(',')}) VALUES $placeholders',
        [for (final row in batch) for (final c in cols) row[c]],
      );
      i = j;
    }
  }

  void _convertMajorUnitsToCents(Map tables) {
    for (final entry in _moneyColumns.entries) {
      final rows = tables[entry.key];
      if (rows is! List) continue;
      for (final raw in rows) {
        if (raw is! Map) continue;
        for (final col in entry.value) {
          final value = raw[col];
          if (value is num) {
            raw[col] = (value * 100).round();
          }
        }
      }
    }
  }
}
