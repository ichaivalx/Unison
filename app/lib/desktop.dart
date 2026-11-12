import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows 窗口：界面自绘的标题栏使用的窗口操作与状态
abstract final class AppWindow {
  static const _channel = MethodChannel('unison/window');

  static bool get supported => Platform.isWindows;

  static final maximized = ValueNotifier(false);
  static final minimized = ValueNotifier(false);

  static Future<void> init() async {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'state') _onState(call.arguments as Map);
    });
    _onState(await _channel.invokeMethod<Map>('state') ?? const {});
  }

  static void _onState(Map state) {
    maximized.value = state['maximized'] == true;
    minimized.value = state['minimized'] == true;
  }

  /// 从当前按下的位置开始拖动窗口
  static void startDrag() => _channel.invokeMethod<void>('startDrag');
  static void minimize() => _channel.invokeMethod<void>('minimize');
  static void toggleMaximize() => _channel.invokeMethod<void>('toggleMaximize');
  static void close() => _channel.invokeMethod<void>('close');
}
