import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Event kinds that match Laravel POS realtime channel intent
/// (`workspace.{id}.pos`). Concrete payloads stay Map-based until
/// Reverb/Pusher credentials are wired.
enum PosEventKind {
  menuOrderCreated,
  orderUpdated,
  tableUpdated,
  invoiceClosed,
}

class PosEvent {
  const PosEvent({
    required this.kind,
    required this.payload,
    required this.at,
    this.source = 'polling',
  });

  final PosEventKind kind;
  final Map<String, dynamic> payload;
  final DateTime at;
  final String source;
}

/// Pluggable POS event source.
///
/// Production path today: [PollingPosEventSource].
/// Future path: [PusherPosEventSource] (disabled until credentials exist).
/// Never claim a live websocket connection without config.
abstract class PosEventSource {
  Stream<PosEvent> get events;
  Future<void> start();
  Future<void> stop();
  String get mode;
}

/// Polling fallback used by Menu Orders / Tables refresh.
class PollingPosEventSource implements PosEventSource {
  PollingPosEventSource({
    required this.poll,
    this.interval = const Duration(seconds: 5),
    this.enabled,
  });

  final Future<List<PosEvent>> Function() poll;
  final Duration interval;
  final bool Function()? enabled;

  final _controller = StreamController<PosEvent>.broadcast();
  Timer? _timer;
  var _running = false;
  var _tickInFlight = false;

  @override
  Stream<PosEvent> get events => _controller.stream;

  @override
  String get mode => 'polling';

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (!_running || _tickInFlight) return;
    if (enabled != null && !enabled!()) return;
    _tickInFlight = true;
    try {
      final batch = await poll();
      for (final event in batch) {
        if (!_controller.isClosed) _controller.add(event);
      }
    } catch (_) {
      // Keep polling; UI shows last known state.
    } finally {
      _tickInFlight = false;
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

/// Stub for Laravel → Reverb/Pusher → Flutter.
///
/// Does **not** connect. Calling [start] throws a clear configuration error
/// so we never fake realtime.
class PusherPosEventSource implements PosEventSource {
  PusherPosEventSource({
    this.appKey,
    this.cluster,
    this.channel,
    this.authEndpoint,
  });

  final String? appKey;
  final String? cluster;
  final String? channel;
  final String? authEndpoint;

  final _controller = StreamController<PosEvent>.broadcast();

  bool get isConfigured =>
      (appKey?.isNotEmpty ?? false) &&
      (cluster?.isNotEmpty ?? false) &&
      (channel?.isNotEmpty ?? false);

  @override
  Stream<PosEvent> get events => _controller.stream;

  @override
  String get mode => 'pusher-unconfigured';

  @override
  Future<void> start() async {
    if (!isConfigured) {
      throw StateError(
        'Realtime Pusher/Reverb غير مُعد. استخدم PollingPosEventSource كـfallback.',
      );
    }
    throw UnimplementedError(
      'ربط Reverb/Pusher جاهز معماريًا ويتطلب credentials فعلية قبل التفعيل.',
    );
  }

  @override
  Future<void> stop() async {}
}

/// Factory: prefer Pusher only when explicitly configured; else polling.
class PosRealtimeFacade {
  PosRealtimeFacade({
    required this.polling,
    this.pusher,
  });

  final PollingPosEventSource polling;
  final PusherPosEventSource? pusher;

  PosEventSource get active {
    final candidate = pusher;
    if (candidate != null && candidate.isConfigured) {
      // Still unimplemented until credentials + package wiring land.
      return polling;
    }
    return polling;
  }

  String get activeMode => active.mode;
}

final posRealtimeModeProvider = Provider<String>((ref) => 'polling');
