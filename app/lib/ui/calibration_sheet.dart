import 'package:flutter/material.dart';

import '../control/calibration.dart';
import '../control/console.dart';
import '../control/models.dart';
import '../control/protocol.dart';
import 'theme.dart';

/// 校准面板：说明、进度、结果与撤销，按频段对齐的滑块。校准在音源上进行，关闭面板
/// 不会中止
Future<void> showCalibrationSheet(BuildContext context, Console console) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => ValueListenableBuilder(
    valueListenable: console.state,
    builder: (context, state, _) =>
        state == null ? const SizedBox(height: 200) : _CalibrationSheet(console: console, state: state),
  ),
);

class _CalibrationSheet extends StatefulWidget {
  const _CalibrationSheet({required this.console, required this.state});

  final Console console;
  final ConsoleState state;

  @override
  State<_CalibrationSheet> createState() => _CalibrationSheetState();
}

class _CalibrationSheetState extends State<_CalibrationSheet> {
  /// 拖动中的对齐位置
  double? _weight;

  /// 拖动中的临时音量
  double? _boostLevel;

  /// 关闭时滑块显示的上次音量
  double _lastBoost = 0.6;

  void _command(String command, [Map<String, Object?> args = const {}]) => widget.console.command(command, args);

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final calibration = state.calibration;
    final stage = calibration.stage;
    final running = stage == CalibrationStage.running;
    final colors = context.colors;
    final texts = context.texts;
    final hint = texts.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.5);
    final playing = state.media?.playing ?? false;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 20 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            switch (stage) {
              CalibrationStage.idle => '声学校准',
              CalibrationStage.running => '正在校准',
              CalibrationStage.done => '校准完成',
              CalibrationStage.failed => '校准未完成',
            },
            style: texts.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (stage == CalibrationStage.idle) ...[
            Text('音源设备用麦克风录下各设备依次发出的测试音，自动设置本机延迟、本机各输出通道的补偿与各接收端的偏移。期间暂停转发音频，请保持安静。', style: hint),
            if (calibration.message case final message?) ...[
              const SizedBox(height: 8),
              Text(message, style: texts.bodyMedium),
            ],
          ],
          if (stage == CalibrationStage.failed && calibration.message != null)
            Text(calibration.message!, style: texts.bodyMedium?.copyWith(color: colors.error)),
          if (running) ...[
            Row(
              children: [
                Expanded(child: Text(calibration.description, style: texts.bodyMedium)),
                if (calibration.totalSteps > 0)
                  Text(
                    '${calibration.step}/${calibration.totalSteps}',
                    style: texts.labelMedium?.copyWith(fontFeatures: tabular, color: colors.onSurfaceVariant),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: calibration.totalSteps > 0 ? calibration.step / calibration.totalSteps : null,
              ),
            ),
            const SizedBox(height: 10),
            Text('请保持安静，各设备会依次发出测试音', style: hint),
          ],
          if (stage == CalibrationStage.done)
            for (final row in calibration.rows) _ResultRow(row: row),
          if (playing && !running) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.pause_circle_outline_rounded, size: 18, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text('正在播放，校准前请先暂停', style: texts.bodySmall)),
                  TextButton(
                    onPressed: () => _command(Command.media, {'action': 'pause'}),
                    child: const Text('暂停'),
                  ),
                ],
              ),
            ),
          ],
          if (!running) ...[
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 16),
            _band(state.band, texts, colors, hint),
            const SizedBox(height: 18),
            _boost(state.boost, texts, colors, hint),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: switch (stage) {
              CalibrationStage.running => [
                FilledButton.tonal(onPressed: () => _command(Command.calibrateCancel), child: const Text('取消')),
              ],
              CalibrationStage.done => [
                if (calibration.canUndo)
                  TextButton(onPressed: () => _command(Command.calibrateUndo), child: const Text('撤销')),
                TextButton(onPressed: () => _command(Command.calibrate), child: const Text('重新校准')),
                FilledButton(
                  onPressed: () {
                    _command(Command.calibrateClose);
                    Navigator.of(context).pop();
                  },
                  child: const Text('完成'),
                ),
              ],
              _ => [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
                FilledButton(
                  onPressed: state.source.running ? () => _command(Command.calibrate) : null,
                  child: Text(stage == CalibrationStage.failed ? '重试' : '开始校准'),
                ),
              ],
            },
          ),
        ],
      ),
    );
  }

  Widget _band(BandView band, TextTheme texts, ColorScheme colors, TextStyle? hint) {
    final weight = _weight ?? band.weight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('对齐频段', style: texts.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(bandPosition(weight), style: texts.labelLarge?.copyWith(color: colors.primary)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          band.available ? '低音没对齐时往「低频」调，人声、高音没对齐时往「中高频」调；手动微调的偏移保留' : '尚无低频的实测数据，校准后可用',
          style: hint,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('中高频', style: hint),
            Expanded(
              child: Slider(
                divisions: 20,
                value: weight,
                onChanged: band.available
                    ? (value) {
                        setState(() => _weight = value);
                        _command(Command.bandWeight, {'weight': value});
                      }
                    : null,
                onChangeEnd: (_) => setState(() => _weight = null),
              ),
            ),
            Text('低频', style: hint),
          ],
        ),
        for (final note in band.notes) Text(note, style: hint),
      ],
    );
  }

  /// 校准时临时提高音量：开关与目标音量
  Widget _boost(double? boost, TextTheme texts, ColorScheme colors, TextStyle? hint) {
    if (boost != null) _lastBoost = boost;
    final level = _boostLevel ?? boost ?? _lastBoost;
    final percent = '${(level * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('校准时临时提高音量', style: texts.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
            Switch(value: boost != null, onChanged: (on) => _command(Command.boost, {'on': on})),
          ],
        ),
        Text(
          boost != null ? '音量低于 $percent 的设备校准期间临时提高到此值，结束后恢复' : '按各设备当前的音量播放测试音',
          style: hint,
        ),
        if (boost != null)
          Row(
            children: [
              Expanded(
                child: Slider(
                  min: 0.3,
                  divisions: 7,
                  value: level.clamp(0.3, 1.0).toDouble(),
                  onChanged: (value) {
                    setState(() => _boostLevel = value);
                    _command(Command.boost, {'level': value});
                  },
                  onChangeEnd: (_) => setState(() => _boostLevel = null),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  percent,
                  textAlign: TextAlign.end,
                  style: texts.labelLarge?.copyWith(color: colors.primary, fontFeatures: tabular),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.row});

  final CalibrationRow row;

  @override
  Widget build(BuildContext context) {
    final texts = context.texts;
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Expanded(child: Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: texts.bodyMedium)),
          Flexible(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  row.result,
                  textAlign: TextAlign.end,
                  style: texts.bodyMedium?.copyWith(fontFeatures: tabular, fontWeight: FontWeight.w600),
                ),
                if (row.detail case final detail?)
                  Text(
                    detail,
                    textAlign: TextAlign.end,
                    style: texts.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
