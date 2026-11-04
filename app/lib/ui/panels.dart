import 'package:flutter/material.dart';

import '../control/calibration.dart';
import '../control/console.dart';
import '../control/models.dart';
import '../control/protocol.dart';
import 'calibration_sheet.dart';
import 'dial.dart';
import 'theme.dart';

/// 圆角面板
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(color: context.colors.surfaceContainer, borderRadius: BorderRadius.circular(24)),
    child: child,
  );
}

/// 区块标题
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
    child: Row(
      children: [
        Text(
          text,
          style: context.texts.titleSmall?.copyWith(color: context.colors.onSurfaceVariant, letterSpacing: 1),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6)],
    ),
  );
}

/// 音源：启动/停止、目标延迟、本机延迟、校准入口
class SourcePanel extends StatelessWidget {
  const SourcePanel({super.key, required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  /// 目标延迟每格 1ms，本机延迟每格 0.5ms
  static const _latencyStep = 1000;
  static const _delayStep = 500;

  @override
  Widget build(BuildContext context) {
    final source = state.source;
    final colors = context.colors;
    final texts = context.texts;
    final receiving = state.devices.where((d) => d.receiving).length;
    final calibrating = state.calibration.stage == CalibrationStage.running;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              StatusDot(color: source.running ? colors.tertiary : colors.outlineVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('音源', style: texts.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      source.running ? (receiving == 0 ? '运行中，暂无设备接收' : '运行中 · $receiving 台设备接收') : '已停止',
                      style: texts.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Switch(
                value: source.running,
                onChanged: (on) => console.command(Command.source, {'on': on}),
              ),
            ],
          ),
          if (source.error case final error?) ...[
            const SizedBox(height: 10),
            Text(error, style: texts.bodySmall?.copyWith(color: colors.error)),
          ],
          const SizedBox(height: 18),
          DialField(
            label: '目标延迟',
            value: (source.latencyUs / _latencyStep).round(),
            min: 0,
            enabled: !calibrating,
            format: (v) => '$v ms',
            onChanged: (v) => console.command(Command.latency, {'us': v * _latencyStep}),
          ),
          const SizedBox(height: 14),
          DialField(
            label: '本机延迟',
            value: (source.localDelayUs / _delayStep).round(),
            min: 0,
            enabled: !calibrating,
            format: (v) => formatMs(v * _delayStep),
            onChanged: (v) => console.command(Command.localDelay, {'us': v * _delayStep}),
          ),
          const SizedBox(height: 18),
          _CalibrationEntry(console: console, state: state),
        ],
      ),
    );
  }
}

class _CalibrationEntry extends StatelessWidget {
  const _CalibrationEntry({required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  @override
  Widget build(BuildContext context) {
    final calibration = state.calibration;
    final running = calibration.stage == CalibrationStage.running;
    final weight = state.band.weight;
    final colors = context.colors;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showCalibrationSheet(context, console),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.multitrack_audio_rounded, color: colors.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('声学校准', style: context.texts.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      running
                          ? '${calibration.description} ${calibration.step}/${calibration.totalSteps}'
                          : '对齐频段：${bandPosition(weight)}',
                      style: context.texts.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (running)
                const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

String bandPosition(double weight) => switch (weight) {
  0.0 => '中高频',
  1.0 => '低频',
  _ => '低频 ${(weight * 100).round()}%',
};

/// 一台设备：在线与同步状态、接收开关、音量与偏移
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.console, required this.device, required this.calibrating});

  final Console console;
  final DeviceView device;

  /// 校准期间偏移不可调
  final bool calibrating;

  /// 偏移每格 0.5ms
  static const _offsetStep = 500;

  IconData get _icon => switch (device.platform) {
    DevicePlatform.windows => Icons.desktop_windows_rounded,
    DevicePlatform.android => device.isSource ? Icons.tablet_android_rounded : Icons.smartphone_rounded,
  };

  (String, Color) _status(ColorScheme colors) {
    if (device.isSource) return ('音源', colors.primary);
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
    final volume = device.actualVolume ?? device.volume.level;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: device.online ? 1 : 0.55,
      child: Panel(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: colors.surfaceContainerHigh, shape: BoxShape.circle),
                  child: Icon(_icon, size: 20, color: device.isSource ? colors.primary : colors.onSurface),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              device.name.isEmpty ? '未命名设备' : device.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: texts.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (self) ...[const SizedBox(width: 8), _Tag('本机', color: colors.primary)],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          StatusDot(color: statusColor),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '${device.platform.label} · $status',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: texts.bodySmall?.copyWith(color: colors.onSurfaceVariant, fontFeatures: tabular),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!device.isSource)
                  Tooltip(
                    message: '接收音频',
                    child: Switch(
                      value: device.receive,
                      onChanged: (on) => _command(Command.receive, {'on': on}),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DialField(
                    label: '音量',
                    value: (volume * 100).round(),
                    min: 0,
                    max: 100,
                    format: (v) => device.isSource || device.volume.mode == VolumeMode.independent
                        ? '$v%'
                        : '$v%  (${_signedPoints(device.volume.offset)})',
                    trailing: device.isSource ? null : _ModeSwitch(device: device, onChanged: _command),
                    onChanged: (v) => _command(Command.volume, {'value': v / 100}),
                  ),
                  if (!device.isSource) ...[
                    const SizedBox(height: 14),
                    DialField(
                      label: '偏移',
                      value: (device.offsetUs / _offsetStep).round(),
                      format: (_) => formatOffset(device.offsetUs),
                      ends: const ('更早', '更晚'),
                      enabled: !calibrating,
                      onDelta: (steps) => _command(Command.offset, {'deltaUs': steps * _offsetStep}),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.device, required this.onChanged});

  final DeviceView device;
  final void Function(String command, Map<String, Object?> args) onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: colors.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mode in VolumeMode.values)
            GestureDetector(
              onTap: () => onChanged(Command.volumeMode, {'mode': mode.name}),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: device.volume.mode == mode ? colors.surfaceContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  mode == VolumeMode.follow ? '跟随' : '独立',
                  style: context.texts.labelMedium?.copyWith(
                    color: device.volume.mode == mode ? colors.onSurface : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: context.texts.labelSmall?.copyWith(color: color)),
  );
}

/// 音量偏移的百分点文本
String _signedPoints(double offset) {
  final points = (offset * 100).round();
  return '${points >= 0 ? '+' : ''}$points';
}
