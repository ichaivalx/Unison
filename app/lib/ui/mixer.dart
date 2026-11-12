import 'dart:async';

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../control/calibration.dart';
import '../control/console.dart';
import '../control/models.dart';
import '../control/protocol.dart';
import '../desktop.dart';
import 'dial.dart';
import 'panels.dart';
import 'theme.dart';

/// 调音台：每台设备一条通道条，音源在前，放不下时横向滚动
class Mixer extends StatefulWidget {
  const Mixer({super.key, required this.console, required this.state});

  static const stripWidth = 140.0;

  /// 通道条的最小高度；可用高度更大时推子随之加长
  static const minHeight = 500.0;

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
    // 有设备可黑屏时各条都留出按键的位置，推子保持对齐
    final blackout = state.devices.any((d) => d.blackout != null);
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
            blackoutRow: blackout,
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
    required this.blackoutRow,
  });

  final Console console;
  final DeviceView device;
  final SourceView source;

  /// 校准期间偏移不可调
  final bool calibrating;

  /// 留出黑屏按键的位置；设备支持黑屏时显示按键
  final bool blackoutRow;

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

  /// 本机直接进入黑屏，其他设备经音源转达
  void _blackout(bool on) {
    if (device.id == console.selfId) {
      Blackout.set(on);
    } else {
      _command(Command.blackout, {'on': on});
    }
  }

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
            SizedBox(
              height: 78,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 10, 0),
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
            if (blackoutRow)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                child: SizedBox(
                  height: 34,
                  child: switch (device.blackout) {
                    null => null,
                    final on => LitButton(
                      label: on ? '退出黑屏' : '黑屏',
                      icon: Icons.bedtime_outlined,
                      on: on,
                      onPressed: () => _blackout(!on),
                    ),
                  },
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

/// 竖向推子（0~100）：细轨道从底部到当前值以主色填充，扁平滑块。上下拖动按相对位移调节，不会
/// 跳到按下处；纵向滚轮每格 1，获得焦点后方向键每次 1、翻页键每次 10。拖动期间以本地值为准、
/// 按绝对值提交
class Fader extends StatefulWidget {
  const Fader({super.key, required this.value, required this.onChanged, required this.label, this.active = true});

  final int value;
  final ValueChanged<int> onChanged;
  final String label;

  /// 有声音经过：填充用主色，否则用低对比度的灰
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
  bool _hovered = false;
  bool _dragging = false;

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

  /// 只接纵向滚动，横向滚动留给外层的横向列表
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      _set(_value + ((event as PointerScrollEvent).scrollDelta.dy < 0 ? 1 : -1));
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

  void _endDrag([_]) => setState(() => _dragging = false);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final emphasized = _hovered || _dragging;
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
            final travel = (constraints.maxHeight - 2 * _FaderPainter.inset).clamp(1.0, double.infinity);
            return MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: Listener(
                onPointerSignal: _onPointerSignal,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => _focus.requestFocus(),
                  onVerticalDragStart: (_) {
                    _drag = 0;
                    _focus.requestFocus();
                    setState(() => _dragging = true);
                  },
                  onVerticalDragUpdate: (details) {
                    _drag -= details.delta.dy / travel * 100;
                    final steps = _drag.truncate();
                    if (steps != 0) {
                      _drag -= steps;
                      _set(_value + steps);
                    }
                  },
                  onVerticalDragEnd: _endDrag,
                  onVerticalDragCancel: _endDrag,
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _FaderPainter(
                      value: _value,
                      emphasized: emphasized,
                      focused: _focused,
                      track: colors.outlineVariant,
                      fill: widget.active ? colors.primary : Color.lerp(colors.outlineVariant, colors.outline, 0.45)!,
                      thumb: colors.surface,
                      index: widget.active ? colors.primary : colors.outlineVariant,
                      focus: colors.primary,
                    ),
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
    required this.emphasized,
    required this.focused,
    required this.track,
    required this.fill,
    required this.thumb,
    required this.index,
    required this.focus,
  });

  /// 滑块中心离轨道两端的距离，悬停放大后仍在范围内
  static const inset = 12.0;

  final int value;

  /// 悬停或拖动中：滑块略放大
  final bool emphasized;
  final bool focused;
  final Color track;
  final Color fill;
  /// 滑块：比通道条更深的近黑色块，中间一条细读数线标出位置
  final Color thumb;
  final Color index;
  final Color focus;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final top = inset;
    final bottom = size.height - inset;
    final y = bottom - (bottom - top) * value / 100;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(x - 3, top, x + 3, bottom), const Radius.circular(3)),
      Paint()..color = track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(x - 3, y, x + 3, bottom), const Radius.circular(3)),
      Paint()..color = fill,
    );

    final handle = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, y), width: emphasized ? 40 : 36, height: emphasized ? 16 : 14),
      const Radius.circular(7),
    );
    canvas.drawRRect(handle, Paint()..color = thumb);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: handle.width - 14, height: 2), const Radius.circular(1)),
      Paint()..color = index,
    );
    if (focused) {
      canvas.drawRRect(
        handle.inflate(3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = focus,
      );
    }
  }

  @override
  bool shouldRepaint(_FaderPainter old) =>
      value != old.value ||
      emphasized != old.emphasized ||
      focused != old.focused ||
      track != old.track ||
      fill != old.fill ||
      thumb != old.thumb ||
      index != old.index;
}
