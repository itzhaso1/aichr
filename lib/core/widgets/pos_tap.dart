import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Lightweight POS tap target without Material ink / MouseRegion.
///
/// Dense cashier grids rebuild often (cart badge, images, auth). Material
/// [InkWell] attaches mouse-tracker annotations that assert during those
/// updates (`no size` / `!_debugDuringDeviceUpdate`).
///
/// This widget:
/// - uses a plain [GestureDetector] (gesture arena stays correct)
/// - gates hit-testing when the box has no size / is empty
/// - defers [onTap] to the next frame so Riverpod setState is not mid hit-test
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
    final VoidCallback? tap = !enabled || onTap == null
        ? null
        : () {
            final cb = onTap!;
            final phase = SchedulerBinding.instance.schedulerPhase;
            // If we're already idle, run now; otherwise wait for the frame.
            if (phase == SchedulerPhase.idle ||
                phase == SchedulerPhase.postFrameCallbacks) {
              cb();
            } else {
              SchedulerBinding.instance.addPostFrameCallback((_) => cb());
            }
          };

    return _HitTestSizedGate(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap,
        child: child,
      ),
    );
  }
}

/// Returns false from [hitTest] when this box was never laid out or is empty,
/// so Flutter's mouse tracker never asserts into `no size` mid-update.
class _HitTestSizedGate extends SingleChildRenderObjectWidget {
  const _HitTestSizedGate({required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHitTestSizedGate();
}

class _RenderHitTestSizedGate extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hasSize || size.isEmpty) return false;
    return super.hitTest(result, position: position);
  }
}
