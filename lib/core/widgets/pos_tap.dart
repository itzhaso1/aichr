import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// POS tap target that never installs a [MouseRegion].
///
/// Material [InkWell] / [IconButton] / [FilledButton] attach mouse-tracker
/// annotations. When the cashier rebuilds under a hovering cursor (cart
/// badge, FAB label, image load), Flutter debug asserts:
/// `!_debugDuringDeviceUpdate` and `Cannot hit test a render box with no size`.
///
/// This render-object tap target:
/// - skips hit-testing when it has no size
/// - defers [onTap] to after the frame so setState is not run mid hit-test
class PosTap extends SingleChildRenderObjectWidget {
  const PosTap({
    super.key,
    required Widget super.child,
    this.onTap,
    this.enabled = true,
    this.defer = true,
  });

  final VoidCallback? onTap;
  final bool enabled;
  final bool defer;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderPosTap(
      onTap: onTap,
      enabled: enabled,
      defer: defer,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderPosTap renderObject) {
    renderObject
      ..onTap = onTap
      ..enabled = enabled
      ..defer = defer;
  }
}

class RenderPosTap extends RenderProxyBox {
  RenderPosTap({
    VoidCallback? onTap,
    bool enabled = true,
    this.defer = true,
  }) : _onTap = onTap,
       _enabled = enabled;

  VoidCallback? _onTap;
  bool _enabled;
  bool defer;
  int? _pointer;
  var _armed = false;

  set onTap(VoidCallback? value) {
    _onTap = value;
  }

  set enabled(bool value) {
    _enabled = value;
  }

  bool get _canTap => _enabled && _onTap != null;

  void _fire() {
    final cb = _onTap;
    if (cb == null || !_enabled) return;
    if (!defer) {
      cb();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) => cb());
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Never assert into Flutter's "!hasSize" path during mouse-tracker updates.
    if (!hasSize || size.isEmpty) return false;
    if (!_canTap) {
      return hitTestChildren(result, position: position);
    }
    if (size.contains(position)) {
      hitTestChildren(result, position: position);
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, covariant HitTestEntry entry) {
    if (!_canTap) return;
    if (event is PointerDownEvent) {
      _pointer = event.pointer;
      _armed = true;
    } else if (event is PointerCancelEvent) {
      if (_pointer == event.pointer) {
        _armed = false;
        _pointer = null;
      }
    } else if (event is PointerUpEvent) {
      if (_armed && _pointer == event.pointer) {
        _armed = false;
        _pointer = null;
        _fire();
      }
    }
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      FlagProperty('enabled', value: _enabled, ifFalse: 'disabled'),
    );
    properties.add(
      FlagProperty('hasOnTap', value: _onTap != null, ifFalse: 'no onTap'),
    );
  }
}

/// Schedule work after the current pointer/mouse-tracker phase.
void posDefer(VoidCallback fn) {
  SchedulerBinding.instance.addPostFrameCallback((_) => fn());
}
