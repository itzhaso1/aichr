import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cashier_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/pos/pos_mode.dart';
import '../../core/audio/menu_sound_service.dart';
import '../../core/config/app_config.dart';
import '../../core/network/cashier_link.dart';
import '../../core/pos/pos_labels.dart';
import '../../core/realtime/pos_event_source.dart';
import '../../core/theme/hasim_colors.dart';
import '../../core/util/json_numbers.dart';
import '../../core/widgets/hasim_widgets.dart';

/// Count of `new` menu orders for nav badge.
final menuNewOrdersCountProvider = StateProvider<int>((ref) => 0);

/// Menu / QR order feed — real section (not toast-only).
class MenuOrdersFeed extends ConsumerStatefulWidget {
  const MenuOrdersFeed({super.key});

  @override
  ConsumerState<MenuOrdersFeed> createState() => _MenuOrdersFeedState();
}

class _MenuOrdersFeedState extends ConsumerState<MenuOrdersFeed> {
  List<Map<String, dynamic>> _orders = const [];
  int? _lastSeenId;
  var _soundEnabled = true;
  var _loadedPrefs = false;
  var _loading = true;
  String? _error;
  String _filter = 'all';
  PollingPosEventSource? _source;
  var _silentTicks = 0;

  static const _statusOptions = [
    'new',
    'accepted',
    'preparing',
    'ready',
    'completed',
    'cancelled',
  ];

  @override
  void initState() {
    super.initState();
    _initSound();
    _startRealtime();
  }

  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }

  Future<void> _initSound() async {
    final sound = ref.read(menuSoundServiceProvider);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    setState(() {
      _soundEnabled = sound.enabled;
      _loadedPrefs = true;
    });
  }

  Future<void> _startRealtime() async {
    _source = PollingPosEventSource(
      interval: Duration(seconds: AppConfig.menuPollSeconds),
      enabled: () => ref.read(cashierLinkProvider).isOnline,
      poll: () async {
        await _fetch(silent: true);
        return const <PosEvent>[];
      },
    );
    await _source!.start();
  }

  Future<void> _fetch({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final session = ref.read(authControllerProvider).valueOrNull;
      if (PosMode.isStandaloneRuntime(
        isLocalMode: session?.isLocalMode == true,
        token: session?.token,
      )) {
        if (!silent && mounted) {
          setState(() {
            _loading = false;
            _error = null;
          });
        }
        return;
      }
      final data = await ref.read(cashierApiProvider).get(
        '/orders/recent-menu',
        query: {
          'after_id': _lastSeenId ?? 0,
        },
      );
      final incremental = <Map<String, dynamic>>[];
      if (data['orders'] is List) {
        for (final item in data['orders'] as List) {
          if (item is Map) {
            incremental.add(Map<String, dynamic>.from(item));
          }
        }
      }
      final latestId = asInt(data['latest_id']);
      if (_lastSeenId != null &&
          incremental.isNotEmpty &&
          mounted &&
          silent) {
        final newest = incremental.first;
        final table =
            newest['table_name'] ?? nestedName(newest['table'], fallback: '—');
        final number = newest['order_number'] ?? newest['id'];
        if (_soundEnabled) {
          await ref.read(menuSoundServiceProvider).playNewOrder();
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('طلب منيو جديد #$number — طاولة $table'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      // Avoid double API hit every poll tick — refresh full board on demand.
      _silentTicks += 1;
      final needsBoard = !silent ||
          incremental.isNotEmpty ||
          _orders.isEmpty ||
          _silentTicks % 6 == 0;

      var list = _orders;
      if (needsBoard) {
        final board = await ref
            .read(cashierApiProvider)
            .get('/orders', query: {'status': 'menu', 'per_page': 50});
        list = <Map<String, dynamic>>[];
        if (board['orders'] is List) {
          for (final item in board['orders'] as List) {
            if (item is Map) list.add(Map<String, dynamic>.from(item));
          }
        }
      }

      if (latestId != null && latestId > 0) {
        _lastSeenId = latestId;
      } else if (list.isNotEmpty) {
        _lastSeenId = asInt(list.first['id']) ?? _lastSeenId;
      }
      final newCount =
          list.where((o) => o['pos_status'] == 'new').length;
      ref.read(menuNewOrdersCountProvider.notifier).state = newCount;
      if (mounted) {
        setState(() {
          _orders = list;
          _loading = false;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted && !silent) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted && !silent) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _updateStatus(int id, String status) async {
    try {
      await ref.read(cashierApiProvider).post(
        '/orders/$id/status',
        data: {'pos_status': status},
      );
      await _fetch(silent: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Color _statusBg(String? status) => switch (status) {
        'new' => HasimColors.warningSoft,
        'accepted' => HasimColors.brandSoft,
        'preparing' => const Color(0xFFEFF6FF),
        'ready' => HasimColors.ctaSoft,
        'cancelled' => HasimColors.dangerSoft,
        _ => HasimColors.navIdleBg,
      };

  Color _statusFg(String? status) => switch (status) {
        'new' => HasimColors.warning,
        'accepted' => HasimColors.brandDark,
        'preparing' => const Color(0xFF1D4ED8),
        'ready' => HasimColors.ctaDark,
        'cancelled' => HasimColors.danger,
        _ => HasimColors.ink,
      };

  List<Map<String, dynamic>> get _filtered {
    if (_filter == 'all') return _orders;
    return _orders.where((o) => o['pos_status'] == _filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final newCount = ref.watch(menuNewOrdersCountProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'طلبات المنيو',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (newCount > 0)
                    HsBadge(
                      label: '$newCount جديد',
                      background: HasimColors.warningSoft,
                      foreground: HasimColors.warning,
                    ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label:
                        Text(_soundEnabled ? 'الصوت: تشغيل' : 'الصوت: إيقاف'),
                    selected: _soundEnabled,
                    onSelected: _loadedPrefs
                        ? (v) async {
                            setState(() => _soundEnabled = v);
                            await ref
                                .read(menuSoundServiceProvider)
                                .setEnabled(v);
                          }
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in [
                      ('all', 'الكل'),
                      ..._statusOptions.map((e) => (e, PosLabels.status(e))),
                    ])
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: FilterChip(
                          label: Text(s.$2),
                          selected: _filter == s.$1,
                          onSelected: (_) => setState(() => _filter = s.$1),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Realtime: ${ref.watch(posRealtimeModeProvider)} (Pusher جاهز معماريًا عند توفر credentials)',
                style: const TextStyle(fontSize: 10, color: HasimColors.muted),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading && _orders.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _orders.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: HsEmpty(
                        title: 'تعذر تحميل طلبات المنيو',
                        subtitle: _error,
                        actionLabel: 'إعادة المحاولة',
                        onAction: () => _fetch(),
                      ),
                    )
                  : filtered.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: HsEmpty(title: 'لا توجد طلبات منيو حالياً'),
                        )
                      : RefreshIndicator(
                          onRefresh: () => _fetch(),
                          child: ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final order = filtered[index];
                              final status = order['pos_status'] as String?;
                              final items = order['items'] is List
                                  ? (order['items'] as List).whereType<Map>()
                                  : const Iterable<Map>.empty();
                              final card = HsCard(
                                color: status == 'new'
                                    ? HasimColors.warningSoft
                                    : HasimColors.surface,
                                borderColor: status == 'new'
                                    ? const Color(0xFFFDE68A)
                                    : HasimColors.border,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            status == 'new'
                                                ? 'طلب جديد #${order['order_number'] ?? order['id']}'
                                                : '#${order['order_number'] ?? order['id']}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ),
                                        HsBadge(
                                          label: PosLabels.status(status),
                                          background: _statusBg(status),
                                          foreground: _statusFg(status),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'الطاولة: ${nestedName(order['table'])} · المصدر: ${order['source']?.toString() ?? 'qr_menu'}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      'وقت الوصول: ${order['created_at'] ?? ''}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: HasimColors.muted,
                                      ),
                                    ),
                                    if (order['notes'] != null &&
                                        (order['notes'] as String)
                                            .isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        'ملاحظات: ${order['notes']}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                    if (items.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      for (final item in items)
                                        Text(
                                          '${item['product_name']} × ${item['quantity']}',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                    ],
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _StatusPickerButton(
                                            value: () {
                                              final raw = status ?? 'new';
                                              return _statusOptions.contains(raw)
                                                  ? raw
                                                  : 'new';
                                            }(),
                                            options: _statusOptions,
                                            onChanged: (v) {
                                              final id = asInt(order['id']);
                                              if (id != null) {
                                                _updateStatus(id, v);
                                              }
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          asDoubleOr(order['total_amount'])
                                              .toStringAsFixed(2),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                              if (index == 0 && status == 'new') {
                                return card
                                    .animate()
                                    .fadeIn(duration: 280.ms)
                                    .slideY(
                                      begin: -0.06,
                                      curve: Curves.easeOut,
                                    );
                              }
                              return card;
                            },
                          ),
                        ),
        ),
      ],
    );
  }
}

class _StatusPickerButton extends StatelessWidget {
  const _StatusPickerButton({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final s in options)
              ListTile(
                title: Text(PosLabels.status(s)),
                selected: s == value,
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != value) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () => _open(context),
      child: Row(
        children: [
          Expanded(
            child: Text(
              PosLabels.status(value),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          const Icon(Icons.keyboard_arrow_down, size: 18),
        ],
      ),
    );
  }
}
