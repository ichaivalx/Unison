import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Windows 窗口：界面自绘的标题栏使用的窗口操作与状态
abstract final class AppWindow {
  static const _channel = MethodChannel('unison/window');

  static bool get supported => Platform.isWindows;

  static final maximized = ValueNotifier(false);
  static final minimized = ValueNotifier(false);

  static Future<void> init() async {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'state':
          _onState(call.arguments as Map);
        // 黑屏期间原生以热键收到的 Esc，与黑屏层内的 Esc 走同一退出路径（重复退出无副作用）
        case 'escape':
          Blackout.set(false);
      }
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

  /// 开机自启：当前用户的启动项存在且指向本程序；启动时驻留托盘、不显示窗口
  static Future<bool> autostart() async => await _channel.invokeMethod<bool>('autostart') ?? false;

  /// 写入或删除启动项，返回之后的实际状态
  static Future<bool> setAutostart(bool on) async => await _channel.invokeMethod<bool>('setAutostart', on) ?? false;
}

/// 卡片、通道条等内容区：其中按下不拖动窗口
class WindowSurface extends StatelessWidget {
  const WindowSurface({super.key, required this.child});

  static const _tag = #windowSurface;

  final Widget child;

  @override
  Widget build(BuildContext context) => MetaData(metaData: _tag, child: child);
}

/// 页面背景上的空白处与标题栏一样：鼠标左键按住拖动窗口、双击最大化或还原。[WindowSurface]
/// 与显示中的滚动条（滑块、轨道）上不响应，触摸照常交给滚动
class WindowDragArea extends StatefulWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  State<WindowDragArea> createState() => _WindowDragAreaState();
}

class _WindowDragAreaState extends State<WindowDragArea> {
  /// 空白处按下的位置，移动超过拖动阈值即交给系统拖动窗口
  Offset? _pressed;

  /// 上一次空白处按下，用于识别双击
  PointerDownEvent? _previous;

  bool _blank(Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData == WindowSurface._tag) return false;
      // 滚动条的绘制层包裹整个滚动内容，只排除落在滚动条交互区域上的按下；滚动条未显示时不排除
      if (target is RenderCustomPaint && entry is BoxHitTestEntry) {
        for (final painter in [target.foregroundPainter, target.painter]) {
          if (painter is ScrollbarPainter && painter.hitTestInteractive(entry.localPosition, PointerDeviceKind.mouse)) {
            return false;
          }
        }
      }
    }
    return true;
  }

  void _down(PointerDownEvent event) {
    _pressed = null;
    if (event.kind != PointerDeviceKind.mouse || event.buttons != kPrimaryMouseButton || !_blank(event.position)) {
      _previous = null;
      return;
    }
    final previous = _previous;
    if (previous != null &&
        event.timeStamp - previous.timeStamp <= kDoubleTapTimeout &&
        (event.position - previous.position).distance <= kDoubleTapSlop) {
      _previous = null;
      AppWindow.toggleMaximize();
      return;
    }
    _previous = event;
    _pressed = event.position;
  }

  void _move(PointerMoveEvent event) {
    final pressed = _pressed;
    if (pressed == null || (event.position - pressed).distance <= kPrecisePointerPanSlop) return;
    _pressed = null;
    _previous = null;
    AppWindow.startDrag();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: (_) => _pressed = null,
    onPointerCancel: (_) => _pressed = null,
    child: widget.child,
  );
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
