import 'package:flutter/material.dart';

import '../network/link_policy.dart';
import '../theme/hasim_colors.dart';
import '../theme/hasim_radius.dart';
import '../theme/hasim_spacing.dart';
import 'pos_tap.dart';

class HsCard extends StatelessWidget {
  const HsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(HasimSpacing.md),
    this.color = HasimColors.surface,
    this.borderColor = HasimColors.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(HasimRadius.lg),
        border: Border.all(color: borderColor),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 8,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class HsPrimaryButton extends StatelessWidget {
  const HsPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return PosTap(
      enabled: enabled,
      onTap: onPressed,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled
              ? HasimColors.cta
              : HasimColors.cta.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(HasimRadius.sm),
        ),
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}

class HsOutlineButton extends StatelessWidget {
  const HsOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return PosTap(
      enabled: enabled,
      onTap: onPressed,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: HasimColors.surface,
          borderRadius: BorderRadius.circular(HasimRadius.sm),
          border: Border.all(
            color: enabled ? HasimColors.cta : HasimColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: enabled ? HasimColors.ctaDark : HasimColors.muted,
          ),
        ),
      ),
    );
  }
}

class HsEmpty extends StatelessWidget {
  const HsEmpty({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return HsCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HasimSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: HasimSpacing.sm),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: HasimSpacing.md),
              PosTap(
                onTap: onAction,
                child: Text(
                  actionLabel!,
                  style: const TextStyle(
                    color: HasimColors.brand,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class HsBadge extends StatelessWidget {
  const HsBadge({
    super.key,
    required this.label,
    this.background = HasimColors.navIdleBg,
    this.foreground = HasimColors.ink,
  });

  final String label;
  final Color background;
  final Color foreground;

  factory HsBadge.occupied(String label) => HsBadge(
        label: label,
        background: HasimColors.occupiedSoft,
        foreground: HasimColors.occupied,
      );

  factory HsBadge.available(String label) => HsBadge(
        label: label,
        background: HasimColors.availableSoft,
        foreground: HasimColors.available,
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(HasimRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

class HsNavPill extends StatelessWidget {
  const HsNavPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PosTap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? HasimColors.navActiveBg : HasimColors.navIdleBg,
          borderRadius: BorderRadius.circular(HasimRadius.sm),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : HasimColors.ink,
          ),
        ),
      ),
    );
  }
}

class HsCategoryTile extends StatelessWidget {
  const HsCategoryTile({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: PosTap(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? HasimColors.brand : HasimColors.surface,
            borderRadius: BorderRadius.circular(HasimRadius.md),
            border: Border.all(
              color: selected ? HasimColors.brand : HasimColors.border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: selected ? Colors.white : HasimColors.ink,
                  ),
                ),
              ),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? Colors.white.withValues(alpha: 0.9)
                      : HasimColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dense POS product card — no Material ink / MouseRegion.
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.name,
    required this.priceLabel,
    required this.currency,
    required this.onAdd,
    this.imageUrl,
    this.sku,
    this.available = true,
  });

  final String name;
  final String priceLabel;
  final String currency;
  final String? imageUrl;
  final String? sku;
  final bool available;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final bounded = constraints.hasBoundedWidth &&
            constraints.hasBoundedHeight &&
            w.isFinite &&
            h.isFinite &&
            w >= 1 &&
            h >= 1;
        if (!bounded) {
          return const SizedBox.shrink();
        }

        final showImage = h >= 168;
        final showSku = h >= 120 && sku != null && sku!.isNotEmpty;
        final showAddChip = h >= 96;

        return Opacity(
          opacity: available ? 1 : 0.55,
          child: PosTap(
            enabled: available,
            onTap: onAdd,
            child: SizedBox(
              width: w,
              height: h,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: HasimColors.surface,
                  borderRadius: BorderRadius.circular(HasimRadius.md),
                  border: Border.all(color: HasimColors.border),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(HasimRadius.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showImage)
                        const Expanded(
                          child: ColoredBox(
                            color: HasimColors.surfaceSoft,
                            // Offline build: never load network images under a
                            // hovering mouse — CachedNetworkImage rebuilds
                            // trip mouse_tracker / no-size asserts.
                            child: Icon(
                              Icons.restaurant_menu,
                              color: Color(0xFFCBD5E1),
                              size: 36,
                            ),
                          ),
                        ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          8,
                          showImage ? 6 : 8,
                          8,
                          8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              name,
                              maxLines: showImage ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                height: 1.2,
                              ),
                            ),
                            if (showSku)
                              Text(
                                sku!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: HasimColors.muted,
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              '$priceLabel $currency',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            if (!available) ...[
                              const SizedBox(height: 4),
                              const Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: HsBadge(
                                  label: 'غير متاح',
                                  background: HasimColors.dangerSoft,
                                  foreground: HasimColors.danger,
                                ),
                              ),
                            ],
                            if (showAddChip) ...[
                              const SizedBox(height: 6),
                              Container(
                                height: 32,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: available
                                      ? HasimColors.ctaSoft
                                      : HasimColors.surfaceSoft,
                                  borderRadius: BorderRadius.circular(
                                    HasimRadius.sm,
                                  ),
                                  border: Border.all(
                                    color: available
                                        ? HasimColors.cta
                                        : HasimColors.border,
                                  ),
                                ),
                                child: Text(
                                  available ? '+ إضافة' : 'غير متوفر',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: available
                                        ? HasimColors.ctaDark
                                        : HasimColors.muted,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({
    super.key,
    required this.link,
    this.pendingCount = 0,
    this.failedCount = 0,
    this.lastSyncAt,
    this.cursor,
    this.deviceId,
    this.onRetry,
  });

  final CashierLink link;
  final int pendingCount;
  final int failedCount;
  final DateTime? lastSyncAt;
  final String? cursor;
  final String? deviceId;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final offline = link != CashierLink.online;
    final waiting = pendingCount + failedCount;
    final statusLabel = switch (link) {
      CashierLink.online => 'متصل',
      CashierLink.offline => 'غير متصل',
      CashierLink.serverUnavailable => 'الخادم غير متاح',
    };
    final detail = offline
        ? (waiting > 0
            ? '$waiting عمليات بانتظار المزامنة'
            : 'الكاشير يعمل محلياً — المزامنة عند عودة الإنترنت')
        : (waiting > 0
            ? '$waiting عمليات بانتظار المزامنة · آخر مزامنة: ${_relative(lastSyncAt)}'
            : 'آخر مزامنة: ${_relative(lastSyncAt)}');

    return Container(
      width: double.infinity,
      color: offline ? HasimColors.warningSoft : HasimColors.ctaSoft,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: offline ? HasimColors.warning : HasimColors.cta,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '● $statusLabel  ·  $detail',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: offline ? HasimColors.warning : HasimColors.ctaDark,
              ),
            ),
          ),
          if (onRetry != null)
            PosTap(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  offline ? 'إعادة المحاولة' : 'مزامنة',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: offline ? HasimColors.warning : HasimColors.ctaDark,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _relative(DateTime? at) {
    if (at == null) return 'لم تتم بعد';
    final diff = DateTime.now().difference(at);
    if (diff.inSeconds < 45) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    return 'منذ ${diff.inDays} يوم';
  }
}
