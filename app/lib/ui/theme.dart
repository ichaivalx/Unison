import 'dart:io';

import 'package:flutter/material.dart';

import '../settings.dart';

const _accent = Color(0xFFF0B46A);
const _onAccent = Color(0xFF241605);
const _text = Color(0xFFEDEDF0);
const _muted = Color(0xFF8E8E97);
const _good = Color(0xFF86D1A8);
const _bad = Color(0xFFF08A80);

/// 接收端通道条顶部的标识色；音源用主色
const receiverMark = Color(0xFF7D93AD);

/// 推子钮的正面
const faderCap = (Color(0xFF4B4E56), Color(0xFF2B2D33));

/// 栅格：页面边距、区块间距与圆角
abstract final class Grid {
  static const unit = 8.0;
  static const gap = 16.0;
  static const narrowMargin = 16.0;
  static const wideMargin = 24.0;
  static const panelRadius = 20.0;
  static const panelPadding = 20.0;
  static const stripRadius = 14.0;
}

/// 两种深色：深灰与纯黑（OLED 可关闭像素）
ThemeData buildTheme(DarkVariant variant) {
  final (background, card, raised, line) = switch (variant) {
    DarkVariant.gray => (
      const Color(0xFF121315),
      const Color(0xFF1B1C20),
      const Color(0xFF25272C),
      const Color(0xFF33353C),
    ),
    DarkVariant.black => (
      const Color(0xFF000000),
      const Color(0xFF0D0D0F),
      const Color(0xFF18191C),
      const Color(0xFF26272C),
    ),
  };
  final scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: _accent,
    onPrimary: _onAccent,
    secondary: _accent,
    onSecondary: _onAccent,
    tertiary: _good,
    onTertiary: Colors.black,
    error: _bad,
    onError: Colors.black,
    surface: background,
    onSurface: _text,
    onSurfaceVariant: _muted,
    surfaceContainerLowest: background,
    surfaceContainerLow: card,
    surfaceContainer: card,
    surfaceContainerHigh: raised,
    surfaceContainerHighest: raised,
    outline: _muted,
    outlineVariant: line,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : null,
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: _text, displayColor: _text),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: _accent,
      inactiveTrackColor: line,
      thumbColor: _accent,
      overlayColor: _accent.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      showValueIndicator: ShowValueIndicator.never,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? _onAccent : _muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? _accent : raised,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? _accent : line,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: card,
      showDragHandle: true,
      dragHandleColor: line,
      constraints: const BoxConstraints(maxWidth: 560),
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStatePropertyAll(BorderSide(color: line)),
        visualDensity: VisualDensity.compact,
      ),
    ),
  );
}

/// 数值用等宽数字，变化时不跳动
const tabular = [FontFeature.tabularFigures()];

extension ThemeX on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get texts => Theme.of(this).textTheme;
}
