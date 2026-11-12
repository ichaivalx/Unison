import 'package:flutter/material.dart';

import '../control/console.dart';
import '../control/models.dart';
import '../desktop.dart';
import 'diagnostics.dart';
import 'media_card.dart';
import 'mixer.dart';
import 'settings_sheet.dart';
import 'source_panel.dart';
import 'theme.dart';
import 'title_bar.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.console, this.desktop = false});

  /// 尚在启动时为 null
  final ValueNotifier<Console?> console;

  /// 桌面窗口：顶栏兼作窗口标题栏
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder(
        valueListenable: console,
        builder: (context, console, _) {
          if (console == null) return _Home(console: null, state: null, desktop: desktop);
          return ListenableBuilder(
            listenable: Listenable.merge([console.state, console.connected]),
            builder: (context, _) => _Home(console: console, state: console.state.value, desktop: desktop),
          );
        },
      ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.console, required this.state, required this.desktop});

  final Console? console;
  final ConsoleState? state;
  final bool desktop;

  /// 不小于此宽度时左右两栏
  static const _wide = 900.0;

  String get _status {
    final console = this.console;
    final state = this.state;
    if (console == null) return '正在启动';
    if (console.isSource) return '本机是音源';
    if (state == null) return '正在寻找音源';
    if (!console.connected.value) return '连接中断，正在重连';
    return '已连接 ${state.device(state.sourceId)?.name ?? '音源'}';
  }

  @override
  Widget build(BuildContext context) {
    final console = this.console;
    final state = this.state;
    final safe = MediaQuery.paddingOf(context);
    final connected = console != null && (console.isSource || (state != null && console.connected.value));
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wide;
        final margin = wide ? Grid.wideMargin : Grid.narrowMargin;
        final bar = TitleBar(
          status: _status,
          connected: connected,
          margin: margin + safe.left,
          desktop: desktop,
          actions: [
            if (desktop && Blackout.supported)
              IconButton(
                tooltip: '黑屏（播放照常，Esc 或点击退出）',
                onPressed: () => Blackout.set(true),
                icon: const Icon(Icons.bedtime_outlined),
              ),
            IconButton(
              tooltip: '设置',
              onPressed: () => showSettingsSheet(context),
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        );
        final insets = EdgeInsets.fromLTRB(margin + safe.left, Grid.unit, margin + safe.right, margin + safe.bottom);
        final Widget body;
        if (console == null || state == null) {
          body = Center(child: _Waiting(text: _status));
        } else if (wide) {
          body = Padding(padding: insets, child: _wideLayout(context, console, state));
        } else {
          body = _narrowLayout(context, console, state, insets);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: safe.top),
            bar,
            Expanded(child: body),
          ],
        );
      },
    );
  }

  Widget _wideLayout(BuildContext context, Console console, ConsoleState state) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final left = constraints.maxWidth >= 1200 ? 400.0 : 360.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: left,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: Grid.gap,
                  children: [
                    SourcePanel(console: console, state: state),
                    MediaCard(console: console, media: state.media),
                    Diagnostics(state: state),
                  ],
                ),
              ),
            ),
            const SizedBox(width: Grid.wideMargin),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final mixer = Mixer(console: console, state: state);
                  if (constraints.maxHeight >= Mixer.minHeight) return mixer;
                  return SingleChildScrollView(child: SizedBox(height: Mixer.minHeight, child: mixer));
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _narrowLayout(BuildContext context, Console console, ConsoleState state, EdgeInsets insets) {
    return ListView(
      padding: insets,
      children: [
        SourcePanel(console: console, state: state),
        const SizedBox(height: Grid.gap),
        MediaCard(console: console, media: state.media),
        const SizedBox(height: Grid.gap),
        SizedBox(height: Mixer.narrowHeight, child: Mixer(console: console, state: state)),
        const SizedBox(height: Grid.gap),
        Diagnostics(state: state),
      ],
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2)),
      const SizedBox(height: 20),
      Text(text, style: context.texts.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
    ],
  );
}
