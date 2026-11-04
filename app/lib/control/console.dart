import 'package:flutter/foundation.dart';

import 'models.dart';

/// 界面使用的控制台：音源设备上直接操作音源，其他设备经控制连接
abstract interface class Console {
  /// 尚未连接过音源时为 null
  ValueListenable<ConsoleState?> get state;

  /// 与音源的连接是否正常（音源设备上始终为 true）
  ValueListenable<bool> get connected;

  String get selfId;

  bool get isSource;

  /// 执行控制台操作，[command] 见 Command
  void command(String command, [Map<String, Object?> args = const {}]);

  /// 音源时刻 [sourceUs] 对应的本机单调时刻
  int localTimeOf(int sourceUs);

  /// 回到前台：[returned] 为从后台返回（而非只是焦点恢复，如收起通知栏）
  void wake({required bool returned});
}
