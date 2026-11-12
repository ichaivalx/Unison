import 'dart:async';

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'theme.dart';

/// 拨轮式的逐格调节：水平拖动逐格滚动并震动，向右增大；鼠标滚轮每次一格
class TickDial extends StatefulWidget {
  const TickDial({super.key, required this.index, required this.onSteps, this.height = 34});

  /// 当前值所在的格
  final int index;

  /// 拖过的格数，正值为增大方向
  final ValueChanged<int> onSteps;
  final double height;

  @override
  State<TickDial> createState() => _TickDialState();
}

class _TickDialState extends State<TickDial> {
  /// 每格的像素
  static const _extent = 10.0;

  /// 未满一格的拖动距离
  double _drag = 0;

  void _onUpdate(DragUpdateDetails details) {
    _drag += details.delta.dx;
    final steps = (_drag / _extent).truncate();
    if (steps != 0) {
      _drag -= steps * _extent;
      HapticFeedback.selectionClick();
      widget.onSteps(steps);
    }
    setState(() {});
  }

  void _onEnd([_]) => setState(() => _drag = 0);

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta;
      final amount = delta.dy != 0 ? -delta.dy : delta.dx;
      if (amount != 0) widget.onSteps(amount > 0 ? 1 : -1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: _onUpdate,
        onHorizontalDragEnd: _onEnd,
        onHorizontalDragCancel: _onEnd,
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: _DialPainter(
              index: widget.index,
              drag: _drag,
              color: colors.onSurface,
              indicatorColor: colors.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.index,
    required this.drag,
    required this.color,
    required this.indicatorColor,
  });

  final int index;
  final double drag;
  final Color color;
  final Color indicatorColor;

  static const _extent = _TickDialState._extent;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2;
    final visible = (mid / _extent).ceil() + 1;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = -visible; i <= visible; i++) {
      final tick = index + i;
      // 刻度随手指移动，较大值在左侧，向中心滚入
      final x = mid - i * _extent + drag;
      if ((x - mid).abs() > mid) continue;
      final major = tick % 10 == 0;
      final length = size.height * (major ? 0.62 : (tick.isEven ? 0.4 : 0.26));
      paint
        ..strokeWidth = major ? 2 : 1.2
        ..color = color.withValues(alpha: major ? 0.6 : 0.3);
      final top = (size.height - length) / 2;
      canvas.drawLine(Offset(x, top), Offset(x, top + length), paint);
    }
    canvas.drawLine(
      Offset(mid, 1),
      Offset(mid, size.height - 1),
      Paint()
        ..color = indicatorColor
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      index != old.index || drag != old.drag || color != old.color || indicatorColor != old.indicatorColor;
}

/// 带标题与数值的拨轮。给出 [onChanged] 时拖动期间以本地值为准、按绝对值提交，
/// 避免状态回传前的连续调节相互覆盖；给出 [onDelta] 时按格数增量提交、显示以状态为准，
/// 用于提交后会被整体平移的值
class DialField extends StatefulWidget {
  const DialField({
    super.key,
    required this.label,
    required this.value,
    required this.format,
    this.onChanged,
    this.onDelta,
    this.min,
    this.max,
    this.trailing,
    this.ends,
    this.enabled = true,
  });

  final String label;

  /// 当前值（格）
  final int value;
  final String Function(int value) format;
  final ValueChanged<int>? onChanged;

  /// 拖过的格数
  final ValueChanged<int>? onDelta;
  final int? min;
  final int? max;

  /// 标题与数值之间的控件
  final Widget? trailing;

  /// 拨轮左右两端的说明
  final (String, String)? ends;

  /// 不可调时拨轮变暗且不响应
  final bool enabled;

  @override
  State<DialField> createState() => _DialFieldState();
}

class _DialFieldState extends State<DialField> {
  static const _hold = Duration(milliseconds: 900);

  int? _pending;
  Timer? _release;

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  void _onSteps(int steps) {
    if (widget.onDelta case final onDelta?) {
      onDelta(steps);
      return;
    }
    final current = _pending ?? widget.value;
    var next = current + steps;
    if (widget.min case final min?) next = next < min ? min : next;
    if (widget.max case final max?) next = next > max ? max : next;
    if (next == current) return;
    setState(() => _pending = next);
    widget.onChanged?.call(next);
    _release?.cancel();
    _release = Timer(_hold, () {
      if (mounted) setState(() => _pending = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final value = _pending ?? widget.value;
    final muted = context.texts.labelSmall?.copyWith(color: context.colors.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(widget.label, style: context.texts.labelLarge?.copyWith(color: context.colors.onSurfaceVariant)),
            const Spacer(),
            if (widget.trailing case final trailing?) ...[trailing, const SizedBox(width: 12)],
            Text(
              widget.format(value),
              style: context.texts.titleSmall?.copyWith(fontFeatures: tabular, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 2),
        IgnorePointer(
          ignoring: !widget.enabled,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: widget.enabled ? 1 : 0.35,
            child: TickDial(index: value, onSteps: _onSteps),
          ),
        ),
        if (widget.ends case (final left, final right))
          Row(
            children: [Text(left, style: muted), const Spacer(), Text(right, style: muted)],
          ),
      ],
    );
  }
}
