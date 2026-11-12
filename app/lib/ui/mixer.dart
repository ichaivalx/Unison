import 'dart:async';

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../control/calibration.dart';
import '../control/console.dart';
import '../control/models.dart';
import '../control/protocol.dart';
import 'dial.dart';
import 'panels.dart';
import 'theme.dart';

/// 调音台：每台设备一条通道条，音源在前，放不下时横向滚动
class Mixer extends StatefulWidget {
  const Mixer({super.key, required this.console, required this.state});

  static const stripWidth = 140.0;

  /// 通道条的最小高度；可用高度更大时推子随之加长
  static const minHeight = 470.0;

  /// 单栏布局中通道条的高度
  static const narrowHeight = 540.0;

  final Console console;
  final ConsoleState state;

  @override
  State<Mixer> createState() => _MixerState();
}

class _MixerState extends State<Mixer> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final calibrating = state.calibration.stage == CalibrationStage.running;
    return Scrollbar(
      controller: _scroll,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: state.devices.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final device = state.devices[index];
          return ChannelStrip(
            key: ValueKey(device.id),
            console: widget.console,
            device: device,
            source: state.source,
            calibrating: calibrating,
          );
        },
      ),
    );
  }
}

/// 一台设备的通道条：标识、同步状态、接收开关、音量模式、推子与偏移
class ChannelStrip extends StatelessWidget {
  const ChannelStrip({
    super.key,
    required this.console,
    required this.device,
    required this.source,
    required this.calibrating,
  });

  final Console console;
  final DeviceView device;
  final SourceView source;

  /// 校准期间偏移不可调
  final bool calibrating;

  /// 偏移每格 0.5ms
  static const _offsetStep = 500;

  IconData get _icon => switch (device.platform) {
    DevicePlatform.windows => Icons.desktop_windows_rounded,
    DevicePlatform.android => device.isSource ? Icons.tablet_android_rounded : Icons.smartphone_rounded,
  };

  (String, Color) _status(ColorScheme colors) {
    if (device.isSource) {
      return source.running ? ('发送中', colors.tertiary) : ('音源已停止', colors.outlineVariant);
    }
    if (!device.online) return ('离线', colors.outlineVariant);
    if (!device.receive) return ('未接收', colors.onSurfaceVariant);
    final stats = device.stats;
    if (!device.receiving || stats == null || !stats.running) return ('等待音频', colors.onSurfaceVariant);
    if (!stats.clockReady) return ('时钟同步中', colors.onSurfaceVariant);
    return ('同步 ±${(stats.syncErrorUs.abs() / 1000).toStringAsFixed(2)} ms', colors.tertiary);
  }

  void _command(String command, Map<String, Object?> args) => console.command(command, {'id': device.id, ...args});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final texts = context.texts;
    final (status, statusColor) = _status(colors);
    final self = device.id == console.selfId;
    final volume = ((device.actualVolume ?? device.volume.level) * 100).round();
    final follow = !device.isSource && device.volume.mode == VolumeMode.follow;
    final muted = texts.labelSmall?.copyWith(color: colors.onSurfaceVariant);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: device.online ? 1 : 0.5,
      child: Container(
        width: Mixer.stripWidth,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Grid.stripRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标识条：音源用主色，接收端用冷色
            Container(height: 4, color: device.isSource ? colors.primary : receiverMark),
            SizedBox(
              height: 74,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_icon, size: 16, color: device.isSource ? colors.primary : colors.onSurfaceVariant),
                        const Spacer(),
                        if (self) Tag('本机', color: colors.primary),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      device.name.isEmpty ? '未命名设备' : device.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: texts.titleSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.2),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 20,
                    child: Row(
                      children: [
                        StatusDot(color: statusColor, size: 7),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muted?.copyWith(fontFeatures: tabular),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (device.isSource)
                    _Plate(label: '音源')
                  else
                    LitButton(
                      label: '接收',
                      on: device.receive,
                      onPressed: device.online ? () => _command(Command.receive, {'on': !device.receive}) : null,
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 28,
                    child: device.isSource
                        ? null
                        : _ModeSwitch(mode: device.volume.mode, onChanged: (mode) => _command(Command.volumeMode, {'mode': mode.name})),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 22,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      spacing: 6,
                      children: [
                        Text(
                          '$volume%',
                          style: texts.titleSmall?.copyWith(fontFeatures: tabular, fontWeight: FontWeight.w600),
                        ),
                        if (follow) Text(_signedPoints(device.volume.offset), style: muted?.copyWith(fontFeatures: tabular)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Fader(
                value: volume,
                active: device.isSource || device.receiving,
                label: '${device.name} 音量',
                onChanged: (v) => _command(Command.volume, {'value': v / 100}),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
              child: device.isSource
                  ? _Readout(label: '本机延迟', value: formatMs(source.localDelayUs))
                  : _OffsetControl(
                      offsetUs: device.offsetUs,
                      enabled: !calibrating && device.online,
                      onSteps: (steps) => _command(Command.offset, {'deltaUs': steps * _offsetStep}),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 音量偏移的百分点文本
String _signedPoints(double offset) {
  final points = (offset * 100).round();
  return '${points >= 0 ? '+' : ''}$points';
}

/// 音源条上与接收开关同位置的标牌
class _Plate extends StatelessWidget {
  const _Plate({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: context.colors.primary.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: context.texts.labelLarge?.copyWith(color: context.colors.primary, fontWeight: FontWeight.w600),
    ),
  );
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final VolumeMode mode;
  final ValueChanged<VolumeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          for (final value in VolumeMode.values)
            Expanded(
              child: Semantics(
                selected: value == mode,
                button: true,
                child: Material(
                  color: value == mode ? colors.outlineVariant : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onChanged(value),
                    child: Center(
                      child: Text(
                        value == VolumeMode.follow ? '跟随' : '独立',
                        style: context.texts.labelMedium?.copyWith(
                          color: value == mode ? colors.onSurface : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: _OffsetControl.height,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.texts.labelSmall?.copyWith(color: context.colors.onSurfaceVariant)),
        const SizedBox(height: 6),
        Text(value, style: context.texts.titleSmall?.copyWith(fontFeatures: tabular, fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

/// 偏移：读数两侧的按钮每次 0.5ms，下方拨轮拖动或滚轮逐格调节
class _OffsetControl extends StatelessWidget {
  const _OffsetControl({required this.offsetUs, required this.enabled, required this.onSteps});

  static const height = 82.0;

  final int offsetUs;
  final bool enabled;
  final ValueChanged<int> onSteps;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final texts = context.texts;
    Widget step(IconData icon, String tooltip, int steps) => SizedBox.square(
      dimension: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        tooltip: tooltip,
        onPressed: enabled ? () => onSteps(steps) : null,
        icon: Icon(icon),
      ),
    );
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('偏移', style: texts.labelSmall?.copyWith(color: colors.onSurfaceVariant)),
          Row(
            children: [
              step(Icons.remove_rounded, '提早 0.5 ms', -1),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatOffset(offsetUs),
                    maxLines: 1,
                    style: texts.labelLarge?.copyWith(fontFeatures: tabular, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              step(Icons.add_rounded, '推迟 0.5 ms', 1),
            ],
          ),
          const SizedBox(height: 2),
          IgnorePointer(
            ignoring: !enabled,
            child: Opacity(
              opacity: enabled ? 1 : 0.35,
              child: TickDial(index: (offsetUs / 500).round(), onSteps: onSteps, height: 30),
            ),
          ),
        ],
      ),
    );
  }
}

/// 竖向推子（0~100）：上下拖动按相对位移调节，不会跳到按下处；滚轮每格 1，获得焦点后方向键
/// 每次 1、翻页键每次 10。拖动期间以本地值为准、按绝对值提交
class Fader extends StatefulWidget {
  const Fader({super.key, required this.value, required this.onChanged, required this.label, this.active = true});

  final int value;
  final ValueChanged<int> onChanged;
  final String label;

  /// 有声音经过：填充用主色，否则用灰色
  final bool active;

  @override
  State<Fader> createState() => _FaderState();
}

class _FaderState extends State<Fader> {
  static const _hold = Duration(milliseconds: 900);

  final _focus = FocusNode();
  int? _pending;
  Timer? _release;
  double _drag = 0;
  bool _focused = false;

  int get _value => _pending ?? widget.value;

  @override
  void dispose() {
    _release?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _set(int next) {
    next = next.clamp(0, 100);
    if (next == _value) return;
    setState(() => _pending = next);
    widget.onChanged(next);
    _release?.cancel();
    _release = Timer(_hold, () {
      if (mounted) setState(() => _pending = null);
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta.dy;
      if (delta != 0) _set(_value + (delta < 0 ? 1 : -1));
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => 1,
      LogicalKeyboardKey.arrowDown => -1,
      LogicalKeyboardKey.pageUp => 10,
      LogicalKeyboardKey.pageDown => -10,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    _set(_value + step);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      label: widget.label,
      value: '$_value%',
      slider: true,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final travel = (constraints.maxHeight - _FaderPainter.capHeight - 2 * _FaderPainter.inset).clamp(1.0, double.infinity);
            return Listener(
              onPointerSignal: _onPointerSignal,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => _focus.requestFocus(),
                onVerticalDragStart: (_) {
                  _drag = 0;
                  _focus.requestFocus();
                },
                onVerticalDragUpdate: (details) {
                  _drag -= details.delta.dy / travel * 100;
                  final steps = _drag.truncate();
                  if (steps != 0) {
                    _drag -= steps;
                    _set(_value + steps);
                  }
                },
                child: CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _FaderPainter(
                    value: _value,
                    focused: _focused,
                    fill: widget.active ? colors.primary : colors.outline,
                    slot: colors.surface,
                    tick: colors.onSurfaceVariant,
                    focus: colors.primary,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FaderPainter extends CustomPainter {
  _FaderPainter({
    required this.value,
    required this.focused,
    required this.fill,
    required this.slot,
    required this.tick,
    required this.focus,
  });

  static const capHeight = 30.0;
  static const capWidth = 46.0;
  static const inset = 6.0;

  final int value;
  final bool focused;
  final Color fill;
  final Color slot;
  final Color tick;
  final Color focus;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final top = inset + capHeight / 2;
    final bottom = size.height - inset - capHeight / 2;
    double yOf(num v) => bottom - (bottom - top) * v / 100;

    // 刻度：每 10 一格，0、50、100 较长
    final ticks = Paint()..strokeWidth = 1;
    for (var v = 0; v <= 100; v += 10) {
      final major = v % 50 == 0;
      final y = yOf(v);
      final length = major ? 9.0 : 5.0;
      ticks.color = tick.withValues(alpha: major ? 0.6 : 0.35);
      canvas
        ..drawLine(Offset(x - 16 - length, y), Offset(x - 16, y), ticks)
        ..drawLine(Offset(x + 16, y), Offset(x + 16 + length, y), ticks);
    }

    // 推子槽与已推起的部分
    final y = yOf(value);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(x - 3, top - 4, x + 3, bottom + 4), const Radius.circular(3)),
      Paint()..color = slot,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(x - 1.5, y, x + 1.5, bottom + 2), const Radius.circular(1.5)),
      Paint()..color = fill.withValues(alpha: 0.85),
    );

    // 推子钮
    final cap = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, y), width: capWidth, height: capHeight),
      const Radius.circular(6),
    );
    canvas.drawShadow(Path()..addRRect(cap), Colors.black, 4, false);
    canvas.drawRRect(
      cap,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [faderCap.$1, faderCap.$2],
        ).createShader(cap.outerRect),
    );
    // 钮面的横纹与读数线
    final grip = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (final dy in [-9.0, -5.0, 5.0, 9.0]) {
      canvas.drawLine(Offset(x - capWidth / 2 + 8, y + dy), Offset(x + capWidth / 2 - 8, y + dy), grip);
    }
    canvas.drawLine(
      Offset(x - capWidth / 2 + 4, y),
      Offset(x + capWidth / 2 - 4, y),
      Paint()
        ..color = const Color(0xFFF2F2F5)
        ..strokeWidth = 2,
    );
    if (focused) {
      canvas.drawRRect(
        cap.inflate(3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = focus,
      );
    }
  }

  @override
  bool shouldRepaint(_FaderPainter old) =>
      value != old.value || focused != old.focused || fill != old.fill || slot != old.slot || tick != old.tick;
}
