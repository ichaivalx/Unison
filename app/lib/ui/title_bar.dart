import 'package:flutter/material.dart';

import '../desktop.dart';
import 'panels.dart';
import 'theme.dart';

/// 页面顶栏：名称与连接状态、设置。桌面上兼作窗口标题栏：拖动移动窗口、双击最大化，
/// 右侧为最小化、最大化与关闭
class TitleBar extends StatelessWidget {
  const TitleBar({
    super.key,
    required this.status,
    required this.connected,
    required this.margin,
    required this.desktop,
    required this.actions,
  });

  static const height = 52.0;

  final String status;
  final bool connected;

  /// 与页面内容对齐的左右边距
  final double margin;
  final bool desktop;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = Row(
      children: [
        Text(
          'Unison',
          style: context.texts.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        ),
        const SizedBox(width: 14),
        StatusDot(color: connected ? colors.tertiary : colors.outline),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(
            child: desktop
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => AppWindow.startDrag(),
                    onDoubleTap: AppWindow.toggleMaximize,
                    child: Padding(padding: EdgeInsets.only(left: margin), child: title),
                  )
                : Padding(padding: EdgeInsets.only(left: margin), child: title),
          ),
          ...actions,
          if (desktop) ...[
            const SizedBox(width: 8),
            const _WindowButtons(),
          ] else
            SizedBox(width: margin - 8),
        ],
      ),
    );
  }
}

class _WindowButtons extends StatelessWidget {
  const _WindowButtons();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: AppWindow.maximized,
    builder: (context, maximized, _) => Row(
      children: [
        _WindowButton(icon: Icons.remove_rounded, tooltip: '最小化', onPressed: AppWindow.minimize),
        _WindowButton(
          icon: maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: maximized ? 14 : 16,
          tooltip: maximized ? '还原' : '最大化',
          onPressed: AppWindow.toggleMaximize,
        ),
        _WindowButton(icon: Icons.close_rounded, tooltip: '关闭', onPressed: AppWindow.close, danger: true),
      ],
    ),
  );
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 16,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;

  /// 关闭：悬停时为红色
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final background = !_hover
        ? Colors.transparent
        : widget.danger
        ? const Color(0xFFC42B1C)
        : colors.surfaceContainerHigh;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: TitleBar.height,
            color: background,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover && widget.danger ? Colors.white : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
