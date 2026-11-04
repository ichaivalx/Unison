import 'package:flutter/material.dart';

import '../control/console.dart';
import '../control/models.dart';
import 'diagnostics.dart';
import 'media_card.dart';
import 'panels.dart';
import 'settings_sheet.dart';
import 'theme.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.console});

  /// 尚在启动时为 null
  final ValueNotifier<Console?> console;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder(
        valueListenable: console,
        builder: (context, console, _) {
          if (console == null) return const _Waiting(text: '正在启动');
          return ListenableBuilder(
            listenable: Listenable.merge([console.state, console.connected]),
            builder: (context, _) => _Home(console: console, state: console.state.value),
          );
        },
      ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.console, required this.state});

  final Console console;
  final ConsoleState? state;

  static const _wide = 900.0;

  String get _status {
    if (console.isSource) return '本机为音源';
    if (state == null) return '正在寻找音源';
    if (!console.connected.value) return '连接中断，正在重连';
    return '已连接 ${state!.device(state!.sourceId)?.name ?? '音源'}';
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final colors = context.colors;
    final connected = console.isSource || (state != null && console.connected.value);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 0, 18),
      child: Row(
        children: [
          Text(
            'Unison',
            style: context.texts.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
          ),
          const SizedBox(width: 14),
          StatusDot(color: connected ? colors.tertiary : colors.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => showSettingsSheet(context),
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
    );
    final state = this.state;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wide;
        final outer = EdgeInsets.fromLTRB(
          (wide ? 28 : 16) + padding.left,
          12 + padding.top,
          (wide ? 28 : 16) + padding.right,
          24 + padding.bottom,
        );
        if (state == null) {
          return Padding(
            padding: outer,
            child: Column(children: [header, const Expanded(child: _Waiting(text: '正在寻找音源'))]),
          );
        }
        final media = MediaCard(console: console, media: state.media);
        final source = SourcePanel(console: console, state: state);
        final devices = [
          SectionTitle('设备', trailing: Text(
            '${state.devices.where((d) => d.online).length} 台在线',
            style: context.texts.labelMedium?.copyWith(color: colors.onSurfaceVariant),
          )),
          for (final device in state.devices) ...[
            DeviceCard(key: ValueKey(device.id), console: console, device: device),
            const SizedBox(height: 12),
          ],
        ];
        final diagnostics = Diagnostics(state: state);
        if (!wide) {
          return ListView(
            padding: outer,
            children: [
              header,
              media,
              const SizedBox(height: 12),
              source,
              const SizedBox(height: 24),
              ...devices,
              const SizedBox(height: 12),
              diagnostics,
            ],
          );
        }
        return SingleChildScrollView(
          padding: outer,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [media, const SizedBox(height: 16), source],
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...devices, const SizedBox(height: 12), diagnostics],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(height: 20),
        Text(text, style: context.texts.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
      ],
    ),
  );
}
