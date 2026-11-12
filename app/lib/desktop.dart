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
  static Future<void> _blackout(bool on) => _channel.invokeMethod<void>('blackout', on);
}

/// 黑屏：窗口全屏覆盖所在的显示器、纯黑并隐藏指针，接收与播放照常；期间系统不关闭显示器、
/// 不睡眠（显示器的扬声器随之断电）。按 Esc 或点击退出，恢复进入前的窗口状态
abstract final class Blackout {
  static bool get supported => AppWindow.supported;

  static final active = ValueNotifier(false);

  static void init() {
    // 期间被最小化（如 Win+D）即结束，窗口保持最小化
    AppWindow.minimized.addListener(() {
      if (AppWindow.minimized.value) set(false);
    });
  }

  static void set(bool on) {
    if (!supported || on == active.value) return;
    active.value = on;
    AppWindow._blackout(on).catchError((_) {});
  }
}
