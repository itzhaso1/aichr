import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/api/cashier_api.dart';
import 'package:hasim_cashier/core/offline/offline_store.dart';
import 'package:hasim_cashier/core/offline/sync_engine.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('cashier_offline_orders_');
    Hive.init(dir.path);
  });

  setUp(() async {
    await OfflineStore.instance.init();
    await OfflineStore.instance.clearAllForTest();
  });

  tearDown(() async {
    await OfflineStore.instance.clearAllForTest();
  });

  tearDownAll(() async {
    await Hive.close();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  Future<String> enqueueSample({
    String key = 'ABC',
    int tableId = 7,
    int workspaceId = 1,
    int qty = 2,
  }) {
    return OfflineStore.instance.enqueueTableOrder(
      tableId: tableId,
      workspaceId: workspaceId,
      idempotencyKey: key,
      notes: 'بدون ثلج',
      items: [
        {
          'pos_menu_item_id': 10,
          'name': 'شاي',
          'quantity': qty,
          'unit_price': 5.0,
          'total_amount': 5.0 * qty,
        },
      ],
    );
  }

  test('1 offline create order saves locally as pending', () async {
    final id = await enqueueSample();
    expect(id, 'ABC');
    final order = OfflineStore.instance.readPending('ABC')!;
    expect(order.idempotencyKey, 'ABC');
    expect(order.localId, 'ABC');
    expect(order.tableId, 7);
    expect(order.orderType, 'table');
    expect(order.status, SyncStatus.pending);
    expect(order.items.first['quantity'], 2);
    expect(OfflineStore.instance.hasUnsyncedTableOrders(7), isTrue);
  });

  test('2 offline edit pending order updates payload not idempotency key',
      () async {
    await enqueueSample();
    await OfflineStore.instance.updatePendingOrder(
      'ABC',
      items: [
        {
          'pos_menu_item_id': 10,
          'name': 'شاي',
          'quantity': 4,
          'unit_price': 5.0,
          'total_amount': 20.0,
        },
      ],
      notes: 'محدّث',
    );
    final order = OfflineStore.instance.readPending('ABC')!;
    expect(order.idempotencyKey, 'ABC');
    expect(order.localId, 'ABC');
    expect(order.items.first['quantity'], 4);
    expect(order.notes, 'محدّث');
    expect(order.toApiPayload()['client_reference'], 'ABC');
    expect(order.toApiPayload()['dining_table_id'], 7);
  });

  test('3 offline delete pending order removes from queue', () async {
    await enqueueSample();
    await OfflineStore.instance.deletePending('ABC');
    expect(OfflineStore.instance.readPending('ABC'), isNull);
    expect(OfflineStore.instance.hasUnsyncedTableOrders(7), isFalse);
  });

  test('4 pending order persists after app restart', () async {
    await enqueueSample();
    await OfflineStore.instance.simulateRestart();
    final order = OfflineStore.instance.readPending('ABC');
    expect(order, isNotNull);
    expect(order!.idempotencyKey, 'ABC');
    expect(order.tableId, 7);
    expect(order.items.first['name'], 'شاي');
  });

  test('5 sync after reconnect posts and marks synced', () async {
    await enqueueSample();
    var posts = 0;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        posts++;
        expect(key, 'ABC');
        expect(payload['client_reference'], 'ABC');
        expect(payload['dining_table_id'], 7);
        expect(payload['order_type'], 'table');
        return {'id': 99, 'order_number': 'T-99'};
      },
    );
    final result = await engine.flushPendingOrders(workspaceId: 1);
    expect(result.synced, 1);
    expect(posts, 1);
    expect(OfflineStore.instance.readPending('ABC')!.status, SyncStatus.synced);
    expect(OfflineStore.instance.readPending('ABC')!.serverOrderId, 99);
  });

  test('6 retry uses the same idempotency key', () async {
    await enqueueSample();
    final keys = <String>[];
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        keys.add(key);
        throw ApiException('timeout', statusCode: 0);
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    await engine.flushPendingOrders(workspaceId: 1);
    expect(keys, ['ABC', 'ABC']);
    expect(OfflineStore.instance.readPending('ABC')!.idempotencyKey, 'ABC');
    expect(OfflineStore.instance.readPending('ABC')!.status, SyncStatus.pending);
  });

  test('7 lost response does not create duplicate order', () async {
    await enqueueSample();
    final created = <String>{};
    var dropNext = true;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        created.add(key);
        if (dropNext) {
          dropNext = false;
          throw ApiException('lost response', statusCode: 0);
        }
        return {'id': 5};
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    expect(OfflineStore.instance.readPending('ABC')!.status, SyncStatus.pending);
    await engine.flushPendingOrders(workspaceId: 1);
    expect(created.length, 1);
    expect(created.single, 'ABC');
    expect(OfflineStore.instance.readPending('ABC')!.status, SyncStatus.synced);
    expect(OfflineStore.instance.readPending('ABC')!.serverOrderId, 5);
  });

  test('8 401 does not mark synced and stops flush', () async {
    await enqueueSample(key: 'A1');
    await enqueueSample(key: 'A2', qty: 1);
    var posts = 0;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        posts++;
        throw ApiException('انتهت الجلسة', statusCode: 401);
      },
    );
    final result = await engine.flushPendingOrders(workspaceId: 1);
    expect(result.authRequired, isTrue);
    expect(posts, 1);
    expect(OfflineStore.instance.readPending('A1')!.status, isNot(SyncStatus.synced));
    expect(OfflineStore.instance.readPending('A2')!.status, SyncStatus.pending);
  });

  test('9 422 moves order to failed and does not retry forever', () async {
    await enqueueSample();
    var posts = 0;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        posts++;
        throw ApiException('أحد أصناف الكاشير غير صالح.', statusCode: 422);
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    await engine.flushPendingOrders(workspaceId: 1);
    expect(posts, 1);
    expect(OfflineStore.instance.readPending('ABC')!.status, SyncStatus.failed);
  });

  test('10 close blocked while pending orders exist', () {
    expect(OfflineStore.instance.hasUnsyncedTableOrders(7), isFalse);
  });

  test('10b close blocked after enqueue', () async {
    await enqueueSample();
    expect(OfflineStore.instance.hasUnsyncedTableOrders(7), isTrue);
    expect(OfflineStore.instance.hasUnsyncedTableOrders(8), isFalse);
  });

  test('11 online payload remains save-only', () {
    final payload = <String, dynamic>{
      'order_type': 'table',
      'dining_table_id': 1,
      'client_reference': 'ref-1',
      'items': [
        {'pos_menu_item_id': 10, 'quantity': 2},
      ],
    };
    expect(payload.containsKey('create_invoice'), isFalse);
    expect(payload.containsKey('payment_method'), isFalse);
    expect(payload['order_type'], 'table');
  });

  test('12 multiple pending orders sync safely with distinct keys', () async {
    await enqueueSample(key: 'K1');
    await enqueueSample(key: 'K2', qty: 3);
    final seen = <String>[];
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        seen.add(key);
        return {'id': seen.length};
      },
    );
    final result = await engine.flushPendingOrders(workspaceId: 1);
    expect(result.synced, 2);
    expect(seen.toSet(), {'K1', 'K2'});
    expect(OfflineStore.instance.readPending('K1')!.status, SyncStatus.synced);
    expect(OfflineStore.instance.readPending('K2')!.status, SyncStatus.synced);
  });

  test('13 sync in-flight guard prevents duplicate flush', () async {
    await enqueueSample();
    var started = 0;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        started++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return {'id': 1};
      },
    );
    final first = engine.flushPendingOrders(workspaceId: 1);
    final second = await engine.flushPendingOrders(workspaceId: 1);
    expect(second.skippedInFlight, isTrue);
    final done = await first;
    expect(done.synced, 1);
    expect(started, 1);
  });

  test('14 no request storm on repeated network failure', () async {
    await enqueueSample();
    var posts = 0;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        posts++;
        throw ApiException('down', statusCode: 503);
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    expect(posts, 1);
    expect(OfflineStore.instance.readPending('ABC')!.status, SyncStatus.pending);
    await engine.flushPendingOrders(workspaceId: 1);
    expect(posts, 2);
  });

  test('sync policy: 401/422/5xx classification', () {
    expect(
      SyncPolicy.fromStatusCode(401, success: false),
      SyncOutcome.stopAuth,
    );
    expect(
      SyncPolicy.fromStatusCode(422, success: false),
      SyncOutcome.markFailed,
    );
    expect(
      SyncPolicy.fromStatusCode(403, success: false),
      SyncOutcome.markFailed,
    );
    expect(
      SyncPolicy.fromStatusCode(0, success: false),
      SyncOutcome.keepPending,
    );
    expect(
      SyncPolicy.fromStatusCode(503, success: false),
      SyncOutcome.keepPending,
    );
    expect(
      SyncPolicy.fromStatusCode(201, success: true),
      SyncOutcome.markSynced,
    );
  });

  test('wrong table id cannot be rewritten on sync payload', () async {
    await enqueueSample(tableId: 7);
    Map<String, dynamic>? sent;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        sent = payload;
        return {'id': 1};
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    expect(sent!['dining_table_id'], 7);
    expect(sent!['order_type'], 'table');
  });

  test('workspace B flush does not fail or post workspace A orders', () async {
    await enqueueSample(key: 'WA', workspaceId: 1);
    await enqueueSample(key: 'WB', workspaceId: 2, tableId: 9);
    final posted = <String>[];
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        posted.add(key);
        return {'id': posted.length};
      },
    );
    final result = await engine.flushPendingOrders(workspaceId: 2);
    expect(result.synced, 1);
    expect(posted, ['WB']);
    expect(OfflineStore.instance.readPending('WA')!.status, SyncStatus.pending);
    expect(OfflineStore.instance.readPending('WA')!.lastError, isNull);
    expect(OfflineStore.instance.readPending('WB')!.status, SyncStatus.synced);
    expect(
      OfflineStore.instance.unsyncedOrders(workspaceId: 1).single.localId,
      'WA',
    );
    expect(
      OfflineStore.instance.hasUnsyncedTableOrders(7, workspaceId: 2),
      isFalse,
    );
    expect(
      OfflineStore.instance.hasUnsyncedTableOrders(7, workspaceId: 1),
      isTrue,
    );
  });

  test('flush without workspace id posts nothing', () async {
    await enqueueSample();
    var posts = 0;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        posts++;
        return {'id': 1};
      },
    );
    final result = await engine.flushPendingOrders();
    expect(result.synced, 0);
    expect(posts, 0);
    expect(OfflineStore.instance.readPending('ABC')!.status, SyncStatus.pending);
  });

  test('retryOne refuses a foreign workspace order', () async {
    await enqueueSample(key: 'WA', workspaceId: 1);
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async => {'id': 1},
    );
    final ok = await engine.retryOne('WA', workspaceId: 2);
    expect(ok, isFalse);
    expect(OfflineStore.instance.readPending('WA')!.status, SyncStatus.pending);
  });

  test('catalog cache is workspace-scoped and does not fall back', () async {
    await OfflineStore.instance.cacheCatalog(
      [
        {'id': 1, 'name': 'شاي أ'},
      ],
      workspaceId: 1,
    );
    await OfflineStore.instance.cacheCatalog(
      [
        {'id': 2, 'name': 'قهوة ب'},
      ],
      workspaceId: 2,
    );
    final a = OfflineStore.instance.readCatalog(workspaceId: 1);
    final b = OfflineStore.instance.readCatalog(workspaceId: 2);
    expect(a.single['name'], 'شاي أ');
    expect(b.single['name'], 'قهوة ب');
    expect(OfflineStore.instance.readCatalog(workspaceId: 3), isEmpty);
  });

  test('several edits before sync send only the final payload', () async {
    await enqueueSample(qty: 1);
    await OfflineStore.instance.updatePendingOrder(
      'ABC',
      items: [
        {
          'pos_menu_item_id': 10,
          'name': 'شاي',
          'quantity': 2,
          'unit_price': 5.0,
          'total_amount': 10.0,
        },
      ],
    );
    await OfflineStore.instance.updatePendingOrder(
      'ABC',
      items: [
        {
          'pos_menu_item_id': 10,
          'name': 'شاي',
          'quantity': 5,
          'unit_price': 5.0,
          'total_amount': 25.0,
        },
      ],
      notes: 'نهائي',
    );
    Map<String, dynamic>? sent;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        sent = payload;
        expect(key, 'ABC');
        return {'id': 44};
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    expect(sent!['client_reference'], 'ABC');
    expect((sent!['items'] as List).single['quantity'], 5);
    expect(sent!['notes'], 'نهائي');
    expect(OfflineStore.instance.readPending('ABC')!.idempotencyKey, 'ABC');
  });

  test('delete after edit before sync removes the order', () async {
    await enqueueSample();
    await OfflineStore.instance.updatePendingOrder(
      'ABC',
      items: [
        {
          'pos_menu_item_id': 10,
          'name': 'شاي',
          'quantity': 9,
          'unit_price': 5.0,
          'total_amount': 45.0,
        },
      ],
    );
    final removed = await OfflineStore.instance.deletePending('ABC');
    expect(removed, isTrue);
    var posts = 0;
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        posts++;
        return {'id': 1};
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    expect(posts, 0);
    expect(OfflineStore.instance.readPending('ABC'), isNull);
  });

  test('edit and delete are refused while syncing', () async {
    await enqueueSample();
    await OfflineStore.instance.markSyncing('ABC');
    final updated = await OfflineStore.instance.updatePendingOrder(
      'ABC',
      items: [
        {
          'pos_menu_item_id': 10,
          'name': 'شاي',
          'quantity': 99,
          'unit_price': 5.0,
          'total_amount': 495.0,
        },
      ],
    );
    expect(updated, isFalse);
    expect(OfflineStore.instance.readPending('ABC')!.items.first['quantity'], 2);
    final deleted = await OfflineStore.instance.deletePending('ABC');
    expect(deleted, isFalse);
    expect(OfflineStore.instance.readPending('ABC'), isNotNull);
  });

  test('restart then retry keeps the same idempotency key', () async {
    await enqueueSample();
    await OfflineStore.instance.simulateRestart();
    final keys = <String>[];
    final engine = SyncEngine(
      OfflineStore.instance,
      postOrder: (payload, key) async {
        keys.add(key);
        expect(payload['client_reference'], 'ABC');
        return {'id': 12};
      },
    );
    await engine.flushPendingOrders(workspaceId: 1);
    expect(keys, ['ABC']);
    expect(OfflineStore.instance.readPending('ABC')!.serverOrderId, 12);
  });

  test('enqueue rejects missing workspace identity', () async {
    expect(
      () => OfflineStore.instance.enqueueOrder(
        {
          'order_type': 'takeaway',
          'client_reference': 'NO-WS',
          'items': [
            {'pos_menu_item_id': 1, 'quantity': 1},
          ],
        },
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
