import 'package:flutter/material.dart';

import '../control/calibration.dart';
import '../control/console.dart';
import '../control/models.dart';
import '../control/protocol.dart';
import 'calibration_sheet.dart';
import 'dial.dart';
import 'panels.dart';
import 'theme.dart';

/// 音源：哪台设备是音源、启停，以及属于音源的目标延迟、本机延迟与校准
class SourcePanel extends StatelessWidget {
  const SourcePanel({super.key, required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  /// 目标延迟每格 1ms，本机延迟每格 0.5ms
  static const _latencyStep = 1000;
  static const _delayStep = 500;

  String get _name {
    final name = state.device(state.sourceId)?.name ?? '';
    return name.isEmpty ? '音源设备' : name;
  }

  Future<void> _toggle(BuildContext context) async {
    final running = state.source.running;
    if (running && !console.isSource) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('停止 $_name 的音源？'),
          content: const Text('所有设备都会停止出声，之后可在任意设备上重新启动。'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('停止音源')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    console.command(Command.source, {'on': !running});
  }

  @override
  Widget build(BuildContext context) {
    final source = state.source;
    final colors = context.colors;
    final texts = context.texts;
    final receiving = state.devices.where((d) => d.receiving).length;
    final calibrating = state.calibration.stage == CalibrationStage.running;
    final local = console.isSource;
    final reachable = local || console.connected.value;
    final hint = texts.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    final action = source.running
        ? (local ? '停止本机音源' : '停止 $_name 的音源')
        : (local ? '启动本机音源' : '启动 $_name 的音源');
    final icon = Icon(source.running ? Icons.stop_rounded : Icons.play_arrow_rounded);
    final self = state.device(console.selfId)?.name;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.podcasts_rounded, color: colors.primary),
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
                            _name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: texts.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (local) ...[const SizedBox(width: 8), Tag('本机', color: colors.primary)],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        StatusDot(color: source.running ? colors.tertiary : colors.outlineVariant),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            source.running
                                ? (receiving == 0 ? '运行中，暂无设备接收' : '运行中，$receiving 台设备在接收')
                                : '已停止',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: hint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Grid.gap),
          if (local)
            source.running
                ? FilledButton.tonalIcon(onPressed: () => _toggle(context), icon: icon, label: Text(action))
                : FilledButton.icon(onPressed: () => _toggle(context), icon: icon, label: Text(action))
          else
            OutlinedButton.icon(onPressed: reachable ? () => _toggle(context) : null, icon: icon, label: Text(action)),
          if (!local && self != null) ...[
            const SizedBox(height: 8),
            Text('本机 $self 是接收端，音源的启停作用于所有设备', style: hint),
          ],
          if (source.error case final error?) ...[
            const SizedBox(height: 10),
            Text(error, style: texts.bodySmall?.copyWith(color: colors.error)),
          ],
          for (final session in source.sessions)
            if (!session.calibrated) ...[
              const SizedBox(height: 8),
              Text('${session.app}：${sessionChannel(session)}', style: texts.bodySmall?.copyWith(color: colors.error)),
            ],
          const SizedBox(height: Grid.gap),
          const Divider(),
          const SizedBox(height: Grid.gap),
          Text('音源设置', style: texts.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
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
