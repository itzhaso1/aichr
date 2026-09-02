import 'package:flutter/widgets.dart';

/// Lightweight POS tap target without Material ink / custom render objects.
///
/// Dense cashier UIs should prefer this over [InkWell] and [IconButton].
class PosTap extends StatelessWidget {
  const PosTap({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: child,
    );
  }
}
