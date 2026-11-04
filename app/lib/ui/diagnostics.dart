import 'package:flutter/material.dart';
import 'package:unison_native/unison_native.dart';

import '../control/calibration.dart';
import '../control/models.dart';
import 'panels.dart';
import 'theme.dart';

/// 收起的诊断信息：音源与各接收端的统计
class Diagnostics extends StatefulWidget {
  const Diagnostics({super.key, required this.state});

  final ConsoleState state;

  @override
  State<Diagnostics> createState() => _DiagnosticsState();
}

class _DiagnosticsState extends State<Diagnostics> {
  bool _open = false;

  static String _stats(ReceiverStats s) => [
    '误差 ${formatMs(s.syncErrorUs)}',
    '缓冲 ${formatMs(s.bufferUs)}',
    '往返 ${formatMs(s.rttUs)}',
    '丢包 ${s.lostPackets}',
    '迟到 ${s.latePackets}',
    '欠载 ${s.xruns}',
    '速率 ${s.speedPpm >= 0 ? '+' : ''}${s.speedPpm.toStringAsFixed(1)} ppm',
    '时钟 ${s.clockReady ? '就绪' : '同步中'}',
    '时间戳 ${s.realTimestamp ? '实测' : '推算'}',
    if (s.outputDevice.isNotEmpty) '输出 ${s.outputDevice}',
  ].join('   ');

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final colors = context.colors;
    final mono = context.texts.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      fontFeatures: tabular,
      height: 1.6,
    );
    final source = state.source;
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Text('诊断信息', style: context.texts.titleSmall?.copyWith(color: colors.onSurfaceVariant)),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more_rounded, color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: !_open
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 10,
                      children: [
                        Text(
                          [
                            '音源 ${source.running ? '运行中' : '已停止'}',
                            '目标延迟 ${formatMs(source.latencyUs)}',
                            '本机延迟 ${formatMs(source.localDelayUs)}',
                            '采集 ${source.sessions.isEmpty ? '无' : source.sessions.join('、')}',
                          ].join('   '),
                          style: mono,
                        ),
                        for (final device in state.devices)
                          if (!device.isSource)
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${device.name}\n',
                                    style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w600),
                                  ),
                                  TextSpan(
                                    text: [
                                      '偏移 ${formatOffset(device.offsetUs)}',
                                      if (device.stats case final stats?) _stats(stats) else '无统计',
                                    ].join('   '),
                                  ),
                                ],
                              ),
                              style: mono,
                            ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
