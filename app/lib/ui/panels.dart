import 'package:flutter/material.dart';

import 'theme.dart';

/// 圆角面板
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(Grid.panelPadding)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: context.colors.surfaceContainer,
      borderRadius: BorderRadius.circular(Grid.panelRadius),
    ),
    child: child,
  );
}

/// 区块标题；并排的区块用它对齐顶部
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  static const height = 36.0;

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(text, style: context.texts.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const Spacer(),
          ?trailing,
        ],
      ),
    ),
  );
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 调音台式的按键：开启时点亮
class LitButton extends StatelessWidget {
  const LitButton({super.key, required this.label, required this.on, this.onPressed, this.icon, this.height = 34});

  final String label;
  final bool on;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onPressed != null;
    final foreground = on ? colors.onPrimary : (enabled ? colors.onSurface : colors.onSurfaceVariant);
    return Semantics(
      toggled: on,
      button: true,
      child: Material(
        color: on ? colors.primary : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: on ? BorderSide.none : BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: height,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 6,
              children: [
                if (icon case final icon?) Icon(icon, size: 16, color: foreground),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.labelLarge?.copyWith(color: foreground, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
    child: Text(text, style: context.texts.labelSmall?.copyWith(color: color)),
  );
}
