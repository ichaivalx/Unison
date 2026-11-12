import 'dart:async';

import 'package:flutter/gestures.dart' show kPrimaryButton, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../desktop.dart';

/// 覆盖整个界面（含弹窗）的黑屏层
class BlackoutLayer extends StatelessWidget {
  const BlackoutLayer({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: Blackout.active,
    builder: (context, active, _) => active ? const _BlackoutScreen() : const SizedBox.shrink(),
  );
}

class _BlackoutScreen extends StatefulWidget {
  const _BlackoutScreen();

  @override
  State<_BlackoutScreen> createState() => _BlackoutScreenState();
}

class _BlackoutScreenState extends State<_BlackoutScreen> {
  /// 提示显示片刻后淡出为纯黑；提示很暗，OLED 上不留亮点
  static const _hintColor = Color(0xFF262626);

  bool _hint = true;
  Timer? _timer;

  /// 黑屏期间持有焦点并接住所有按键，底层控件收不到键盘操作；退出后焦点交回原处
  final _focus = FocusNode(debugLabel: 'blackout');
  FocusNode? _previous;

  /// 用于退出的这次点击：抬起时退出，整个手势由黑屏层接住
  int? _exitPointer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 2), () => setState(() => _hint = false));
    _previous = FocusManager.instance.primaryFocus;
    // 黑屏层位于导航之外，自动获取焦点不会从当前页面取走焦点，挂载后主动请求
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focus.dispose();
    final previous = _previous;
    if (previous != null && previous.context != null && previous.canRequestFocus) previous.requestFocus();
    super.dispose();
  }

  /// Esc 退出；其余按键也由黑屏接住
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) Blackout.set(false);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    onKeyEvent: _onKey,
    child: _pointerLayer(),
  );

  Widget _pointerLayer() => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) {
      if (event.buttons & (kPrimaryButton | kSecondaryButton) != 0) _exitPointer = event.pointer;
    },
    onPointerUp: (event) {
      if (event.pointer == _exitPointer) Blackout.set(false);
    },
    onPointerCancel: (_) => _exitPointer = null,
    onPointerSignal: (_) {},
    child: MouseRegion(
      cursor: SystemMouseCursors.none,
      opaque: true,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: AnimatedOpacity(
            opacity: _hint ? 1 : 0,
            duration: const Duration(milliseconds: 600),
            child: const Text(
              '按 Esc 或点击退出黑屏',
              style: TextStyle(inherit: false, color: _hintColor, fontSize: 14),
            ),
          ),
        ),
      ),
    ),
  );
}
