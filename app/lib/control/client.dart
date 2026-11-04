import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:unison_native/unison_native.dart';

import '../settings.dart';
import 'clock.dart';
import 'console.dart';
import 'models.dart';
import 'protocol.dart';
import 'transport.dart';

/// 非音源设备：连接音源作控制台，并按音源下发的设置接收音频、设置音量
class ConsoleClient implements Console {
  ConsoleClient._();

  static Future<ConsoleClient> start() async {
    final client = ConsoleClient._();
    await client._start();
    return client;
  }

  /// 本机设音量后此时间内的音量变化视为自身所致
  static const _selfVolumeUs = 1000000;

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

  late final _transport = ConsoleTransport(
    onConnected: _onConnected,
    onMessage: _onMessage,
    onDisconnected: () => _connected.value = false,
    onSource: (source) => LocalSettings.lastSource = source,
    lastSource: LocalSettings.lastSource,
  );

  int? _receiverId;

  /// 无时钟样本时，按收到状态的时刻估计的音源时钟差
  int _fallbackOffsetUs = 0;

  /// 以下为原生调用成功后的实际状态
  bool _receiverOn = false;
  String? _receiverHost;
  int? _offsetUs;
  double? _targetVolume;

  int _startedAt = 0;
  ReceiverStats? _stats;
  double? _volume;
  int _selfVolumeUntil = 0;
  Future<void> _applying = Future.value();
  bool _busy = false;

  /// 原生侧自行停止了接收（如通知栏停止），尚待音源确认关闭接收开关
  bool _stoppedNatively = false;

  Future<void> _start() async {
    UnisonNative.receiverStats.listen(_onStats, onError: (_) {});
    UnisonNative.volumeChanges.listen(_onVolume, onError: (_) {});
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
        await UnisonNative.setOutputDevice(device);
      } catch (_) {}
    }
    try {
      _volume = await UnisonNative.volume();
    } catch (_) {}
  }

  @override
  void wake() {
    _transport.wake();
    _report();
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
    if (_stoppedNatively) _sendReceiveOff();
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
      case MessageType.apply:
        final host = _transport.connection?.address;
        if (host != null) _applying = _applying.then((_) => _apply(message, host));
    }
  }

  /// 按下发的设置调用原生；只在调用成功后更新实际状态，失败的由音源按回报重发
  Future<void> _apply(Message message, String host) async {
    _busy = true;
    final receive = message['receive'] == true;
    // 原生侧停止接收后，等音源确认关闭前不再按旧设置启动
    if (!receive) _stoppedNatively = false;
    if (receive && !_stoppedNatively) {
      if (!_receiverOn || _receiverHost != host) {
        try {
          await UnisonNative.startReceiver(sourceHost: host);
          _receiverOn = true;
          _receiverHost = host;
          _offsetUs = null;
          _startedAt = nowUs;
        } catch (_) {}
      }
      if (_receiverOn) {
        if (message['offsetUs'] case final int offset when offset != _offsetUs) {
          try {
            await UnisonNative.setReceiverOffsetUs(offset);
            _offsetUs = offset;
          } catch (_) {}
        }
      }
    } else if (_receiverOn) {
      try {
        await UnisonNative.stopReceiver();
        _clearReceiver();
      } catch (_) {}
    }
    if (message['volume'] case final num value) {
      final volume = value.toDouble();
      if (volume != _targetVolume) {
        _selfVolumeUntil = nowUs + _selfVolumeUs;
        try {
          await UnisonNative.setVolume(volume);
          _targetVolume = volume;
        } catch (_) {}
      }
    }
    _busy = false;
    _report();
  }

  void _clearReceiver() {
    _receiverOn = false;
    _receiverHost = null;
    _offsetUs = null;
  }

  void _onStats(ReceiverStats stats) {
    _stats = stats;
    if (!_receiverOn || stats.running || _busy || nowUs - _startedAt < _startGraceUs) return;
    // 不是控制面停止的：同步关闭接收开关，否则重连后不会再启动
    _clearReceiver();
    _stoppedNatively = true;
    _sendReceiveOff();
    _report();
  }

  void _sendReceiveOff() => command(Command.receive, {'id': selfId, 'on': false});

  void _onVolume(double volume) {
    _volume = volume;
    if (nowUs < _selfVolumeUntil) {
      _report();
      return;
    }
    // 用户在本机调整：音源据此改写设置，再下发同样的音量
    _targetVolume = volume;
    _transport.send({'t': MessageType.localVolume, 'volume': volume});
  }

  void _report() {
    final stats = _stats;
    _transport.send({
      't': MessageType.report,
      'stats': stats == null || !_receiverOn ? null : statsToJson(stats),
      'volume': _volume,
      'receiving': _receiverOn,
      'offsetUs': _offsetUs,
      'appliedVolume': _targetVolume,
    });
  }
}
