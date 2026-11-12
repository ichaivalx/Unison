import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:unison_native/unison_native.dart';

import '../desktop.dart';
import '../settings.dart';
import 'clock.dart';
import 'console.dart';
import 'models.dart';
import 'protocol.dart';
import 'transport.dart';
import 'volume.dart';

/// 非音源设备：连接音源作控制台，并按音源下发的设置接收音频、设置音量
class ConsoleClient implements Console {
  ConsoleClient._();

  static Future<ConsoleClient> start() async {
    final client = ConsoleClient._();
    await client._start();
    return client;
  }

  /// 开始接收后此时间内的统计可能仍是开始前的，不据此判断接收已停
  static const _startGraceUs = 2000000;

  final _state = ValueNotifier<ConsoleState?>(null);
  final _connected = ValueNotifier(false);

  @override
  ValueListenable<ConsoleState?> get state => _state;

  @override
  ValueListenable<bool> get connected => _connected;

  @override
  String get selfId => LocalSettings.deviceId;

  @override
  bool get isSource => false;

  late ConsoleTransport _transport = _newTransport();

  ConsoleTransport _newTransport() => ConsoleTransport(
    onConnected: _onConnected,
    onMessage: _onMessage,
    onDisconnected: () {
      _connected.value = false;
      _session++;
      _restoreBoost();
    },
    onSource: (source) => LocalSettings.lastSource = source,
    lastSource: LocalSettings.lastSource,
  );

  /// 用户从通知退出后不再连接，回到前台时重新开始
  bool _exited = false;

  int? _receiverId;

  /// 无时钟样本时，按收到状态的时刻估计的音源时钟差
  int _fallbackOffsetUs = 0;

  /// 以下为原生调用后的实际状态：调用成功即记录（所属连接已断开也记录），结果拿不准时
  /// 为 null（未知），按未生效回报，下次下发时重新调用核对
  bool? _receiverOn = false;
  String? _receiverHost;
  int? _offsetUs;
  double? _targetVolume;

  int _startedAt = 0;
  ReceiverStats? _stats;
  double? _volume;
  late final _volumes = VolumeSetter(onUser: _onUserVolume);

  /// 校准临时提高音量前的音量：退出或断开时自行恢复，期间用户调整过则不再恢复
  double? _boostFrom;
  Future<void> _applying = Future.value();
  bool _busy = false;

  /// 控制连接的代次：断开或退出时递增，旧连接上待执行和执行中的设置随之作废
  int _session = 0;

  /// 用户从通知退出后，尚待音源确认关闭本机接收开关
  bool _receiveOffPending = false;

  Future<void> _start() async {
    UnisonNative.receiverStats.listen(_onStats, onError: (_) {});
    UnisonNative.volumeChanges.listen(_onVolume, onError: (_) {});
    UnisonNative.exitRequests.listen((_) => _exit(), onError: (_) {});
    // 本机进入或退出黑屏（含本机手动退出）时立即回报
    Blackout.active.addListener(_report);
    await _transport.start();
    Timer.periodic(const Duration(seconds: 1), (_) => _report());
    _initNative();
  }

  /// 原生调用可能排在音源进程启动之后，不阻塞连接；取得接收端 id 后重新登记
  Future<void> _initNative() async {
    try {
      _receiverId = await UnisonNative.receiverId();
      if (_transport.isConnected) _hello();
    } catch (_) {}
    if (LocalSettings.outputDevice case final device?) {
      try {
        await UnisonNative.setOutputDevice(device.id);
      } catch (_) {}
    }
    try {
      final volume = await UnisonNative.volume();
      _volumes.isUser(volume);
      _volume = volume;
    } catch (_) {}
  }

  /// 从后台回到前台时解除退出、保持常驻（首次会申请通知权限）；只是焦点恢复（如
  /// 收起通知栏）时只确认现有连接，不撤销退出
  @override
  void wake({required bool returned}) {
    if (_exited) {
      if (!returned) return;
      _exited = false;
      _transport = _newTransport();
      _transport.start().catchError((_) {});
    } else {
      _transport.wake();
      _report();
    }
    if (returned && Platform.isAndroid) UnisonNative.setKeepAlive(true).catchError((_) {});
  }

  /// 通知上的“退出”：原生已停止接收与常驻；同步关闭本机接收开关，断开且不再重连
  Future<void> _exit() async {
    if (_exited) return;
    _exited = true;
    _session++;
    _clearReceiver();
    // 未送达时重连后补发，确认前不按旧设置重新接收
    _receiveOffPending = true;
    _sendReceiveOff();
    _restoreBoost();
    await _transport.dispose();
    _connected.value = false;
  }

  @override
  int localTimeOf(int sourceUs) =>
      _transport.clock.toLocal(sourceUs) ?? sourceUs + _fallbackOffsetUs;

  @override
  void command(String command, [Map<String, Object?> args = const {}]) {
    _transport.send({...args, 't': MessageType.command, 'c': command});
  }

  void _onConnected() {
    _connected.value = true;
    _hello();
    if (_receiveOffPending) _sendReceiveOff();
    _report();
  }

  void _hello() {
    _transport.send({
      't': MessageType.hello,
      'version': Protocol.version,
      'id': selfId,
      'name': LocalSettings.deviceName,
      'platform': LocalSettings.platform.name,
      'receiverId': _receiverId,
      'blackout': Blackout.supported,
    });
  }

  void _onMessage(Message message) {
    switch (message['t']) {
      case MessageType.incompatible:
        _transport.reject();
      case MessageType.state:
        if (ConsoleState.fromJson(message['s']) case final state?) {
          _fallbackOffsetUs = nowUs - state.sentAtUs;
          _state.value = state;
        }
      case MessageType.blackout:
        Blackout.set(message['on'] == true);
      case MessageType.apply:
        final host = _transport.connection?.address;
        final session = _session;
        if (host != null) _applying = _applying.then((_) => _apply(message, host, session));
    }
  }

  /// 按下发的设置调用原生，失败的由音源按回报重发。所属连接已断开（[session] 过期）
  /// 时不再执行后续步骤，但已完成的原生调用照常记录实际状态，重连后据此核对；断开时
  /// 的恢复之后不会再有旧设置调高音量
  Future<void> _apply(Message message, String host, int session) async {
    bool stale() => session != _session;
    if (stale()) return;
    _busy = true;
    try {
      final receive = message['receive'] == true;
      // 退出后，等音源确认关闭前不再按旧设置启动
      if (!receive) _receiveOffPending = false;
      if (receive && !_receiveOffPending) {
        if (_receiverOn != true || _receiverHost != host) {
          // 换音源地址时原生先停旧流：新流启动成功前按未接收回报
          _clearReceiver();
          try {
            await UnisonNative.startReceiver(sourceHost: host);
            _receiverOn = true;
            _receiverHost = host;
            _startedAt = nowUs;
          } catch (_) {
            // 旧流是否已停拿不准
            _receiverOn = null;
          }
          // 启动期间用户已退出：按退出停下这次启动的接收
          if (_exited && _receiverOn != false) {
            await _stopReceiver();
            return;
          }
          if (stale()) return;
        }
        if (_receiverOn == true) {
          if (message['offsetUs'] case final int offset when offset != _offsetUs) {
            try {
              await UnisonNative.setReceiverOffsetUs(offset);
              // 期间已因退出停止接收的不再记录
              if (_receiverOn == true) _offsetUs = offset;
            } catch (_) {
              _offsetUs = null;
            }
            if (stale()) return;
          }
        }
      } else if (_receiverOn != false) {
        await _stopReceiver();
        if (stale()) return;
      }
      if (message['volume'] case final num value) {
        final volume = value.toDouble();
        // 快照在调高之前同步建立，断开时的恢复总排在这次设定之后
        if (message['boost'] != true) {
          _boostFrom = null;
        } else {
          _boostFrom ??= _volume;
        }
        if (volume != _targetVolume) {
          try {
            final actual = await _volumes.set(volume);
            if (stale()) {
              // 断开时的恢复可能与这次设定交错，最终音量拿不准
              _targetVolume = null;
              return;
            }
            _volume = actual;
            _targetVolume = volume;
          } catch (_) {
            _targetVolume = null;
          }
        }
      }
    } finally {
      _busy = false;
    }
    _report();
  }

  Future<void> _stopReceiver() async {
    try {
      await UnisonNative.stopReceiver();
      _clearReceiver();
    } catch (_) {
      _receiverOn = null;
    }
  }

  void _clearReceiver() {
    _receiverOn = false;
    _receiverHost = null;
    _offsetUs = null;
  }

  void _onStats(ReceiverStats stats) {
    _stats = stats;
    if (_receiverOn != true || stats.running || _busy || nowUs - _startedAt < _startGraceUs) return;
    // 接收意外停止：按未接收回报，由音源按接收开关重发恢复
    _clearReceiver();
    _report();
  }

  void _sendReceiveOff() => command(Command.receive, {'id': selfId, 'on': false});

  void _onVolume(double volume) {
    if (_volumes.isUser(volume)) {
      _onUserVolume(volume);
      return;
    }
    _volume = volume;
    _report();
  }

  /// 用户在本机调整：音源据此改写设置，再下发同样的音量；临时提高期间则不再恢复
  void _onUserVolume(double volume) {
    _volume = volume;
    _boostFrom = null;
    _targetVolume = volume;
    _transport.send({'t': MessageType.localVolume, 'volume': volume});
  }

  /// 恢复校准临时提高前的音量；重连后按音源下发的设置重新设定
  void _restoreBoost() {
    final volume = _boostFrom;
    if (volume == null) return;
    _boostFrom = null;
    _targetVolume = null;
    _volumes.set(volume).then((actual) => _volume = actual, onError: (_) {});
  }

  void _report() {
    final stats = _stats;
    _transport.send({
      't': MessageType.report,
      'stats': stats == null || _receiverOn != true ? null : statsToJson(stats),
      'volume': _volume,
      'receiving': _receiverOn,
      'offsetUs': _offsetUs,
      'appliedVolume': _targetVolume,
      'blackout': Blackout.active.value,
    });
  }
}
