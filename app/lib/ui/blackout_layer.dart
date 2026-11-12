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

  /// 用于退出的这次点击：抬起时退出，整个手势由黑屏层接住
  int? _exitPointer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 2), () => setState(() => _hint = false));
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    _timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// 黑屏期间按键都由黑屏接住，Esc 退出
  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) Blackout.set(false);
    return true;
  }

  @override
  Widget build(BuildContext context) => Listener(
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
