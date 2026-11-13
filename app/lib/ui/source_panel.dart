import 'package:flutter/material.dart';

import '../control/calibration.dart';
import '../control/console.dart';
import '../control/models.dart';
import '../control/protocol.dart';
import 'calibration_sheet.dart';
import 'dial.dart';
import 'panels.dart';
import 'theme.dart';

/// 音源：哪台设备是音源、启停，以及属于音源的目标延迟、本机延迟与校准，合成一整块面板（宽布局）。
/// 窄布局拆成置顶的 [SourceBar] 与下沉的 [SourceSettingsPanel]
class SourcePanel extends StatelessWidget {
  const SourcePanel({super.key, required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SourceHeader(console: console, state: state, compact: false),
        const SizedBox(height: Grid.gap),
        const Divider(),
        const SizedBox(height: Grid.gap),
        _SourceSettings(console: console, state: state),
      ],
    ),
  );
}

/// 窄布局的音源条：设备与启停占一行，告警在其下
class SourceBar extends StatelessWidget {
  const SourceBar({super.key, required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.symmetric(horizontal: Grid.panelPadding, vertical: 12),
    child: _SourceHeader(console: console, state: state, compact: true),
  );
}

/// 窄布局下沉的音源设置
class SourceSettingsPanel extends StatelessWidget {
  const SourceSettingsPanel({super.key, required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  @override
  Widget build(BuildContext context) => Panel(child: _SourceSettings(console: console, state: state));
}

/// 音源设备、启停与告警。紧凑时启停按钮与设备并排，只写动作
class _SourceHeader extends StatelessWidget {
  const _SourceHeader({required this.console, required this.state, required this.compact});

  final Console console;
  final ConsoleState state;
  final bool compact;

  String get _name {
    final name = state.device(state.sourceId)?.name ?? '';
    return name.isEmpty ? '音源设备' : name;
  }

  void _toggle() => console.command(Command.source, {'on': !state.source.running});

  @override
  Widget build(BuildContext context) {
    final source = state.source;
    final colors = context.colors;
    final texts = context.texts;
    final local = console.isSource;
    final reachable = local || console.connected.value;
    final hint = texts.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    final alert = texts.bodySmall?.copyWith(color: colors.error);
    final verb = source.running ? '停止' : '启动';
    final action = compact ? verb : (local ? '$verb本机音源' : '$verb $_name 的音源');
    final icon = Icon(source.running ? Icons.stop_rounded : Icons.play_arrow_rounded);
    // 紧凑时收窄图标与按钮，把宽度留给设备名
    final style = compact ? const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12))) : null;
    final mark = compact ? 40.0 : 44.0;
    final Widget button = local
        ? source.running
              ? FilledButton.tonalIcon(onPressed: _toggle, style: style, icon: icon, label: Text(action))
              : FilledButton.icon(onPressed: _toggle, style: style, icon: icon, label: Text(action))
        : OutlinedButton.icon(onPressed: reachable ? _toggle : null, style: style, icon: icon, label: Text(action));
    final self = state.device(console.selfId)?.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: mark,
              height: mark,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.podcasts_rounded, color: colors.primary),
            ),
            SizedBox(width: compact ? 12 : 14),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      _name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (compact ? texts.titleMedium : texts.titleLarge)?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (local) ...[const SizedBox(width: 8), Tag('本机', color: colors.primary)],
                ],
              ),
            ),
            if (compact) ...[const SizedBox(width: 8), button],
          ],
        ),
        if (!compact) ...[
          const SizedBox(height: Grid.gap),
          button,
          if (!local && self != null) ...[
            const SizedBox(height: 8),
            Text('本机 $self 是接收端，音源的启停作用于所有设备', style: hint),
          ],
        ],
        if (source.error case final error?) ...[
          const SizedBox(height: 10),
          Text(error, style: alert),
        ],
        for (final session in source.sessions)
          if (!session.calibrated) ...[
            const SizedBox(height: 8),
            Text('${session.app}：${sessionChannel(session)}', style: alert),
          ],
        for (final session in source.uncaptured) ...[
          const SizedBox(height: 8),
          Text(
            '${session.app}：无法采集，声音不会同步到其他设备。它的输出方式绕过了音效（快速或直通通道），本机播放不受影响',
            style: alert,
          ),
        ],
      ],
    );
  }
}

/// 目标延迟、本机延迟与校准入口
class _SourceSettings extends StatelessWidget {
  const _SourceSettings({required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  /// 目标延迟每格 1ms，本机延迟每格 0.5ms
  static const _latencyStep = 1000;
  static const _delayStep = 500;

  @override
  Widget build(BuildContext context) {
    final source = state.source;
    final calibrating = state.calibration.stage == CalibrationStage.running;
    final reachable = console.isSource || console.connected.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('音源设置', style: context.texts.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        DialField(
          label: '目标延迟',
          value: (source.latencyUs / _latencyStep).round(),
          min: 0,
          enabled: !calibrating && reachable,
          format: (v) => '$v ms',
          onChanged: (v) => console.command(Command.latency, {'us': v * _latencyStep}),
        ),
        const SizedBox(height: 14),
        DialField(
          label: '本机延迟',
          value: (source.localDelayUs / _delayStep).round(),
          min: 0,
          enabled: !calibrating && reachable,
          format: (v) => formatMs(v * _delayStep),
          onChanged: (v) => console.command(Command.localDelay, {'us': v * _delayStep}),
        ),
        const SizedBox(height: Grid.gap),
        _CalibrationEntry(console: console, state: state),
      ],
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
    final colors = context.colors;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
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
                          : '对齐频段：${bandPosition(state.band.weight)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
