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

  bool _receiverOn = false;
  String? _receiverHost;
  int? _offsetUs;
  double? _targetVolume;
  ReceiverStats? _stats;
  double? _volume;
  int _selfVolumeUntil = 0;
  Future<void> _applying = Future.value();

  Future<void> _start() async {
    UnisonNative.receiverStats.listen((stats) => _stats = stats, onError: (_) {});
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
  void wake() => _transport.wake();

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

  Future<void> _apply(Message message, String host) async {
    try {
      if (message['receive'] == true) {
        if (!_receiverOn || _receiverHost != host) {
          await UnisonNative.startReceiver(sourceHost: host);
          _receiverOn = true;
          _receiverHost = host;
          _offsetUs = null;
        }
        if (message['offsetUs'] case final int offset when offset != _offsetUs) {
          await UnisonNative.setReceiverOffsetUs(offset);
          _offsetUs = offset;
        }
      } else if (_receiverOn) {
        _receiverOn = false;
        _receiverHost = null;
        await UnisonNative.stopReceiver();
      }
      if (message['volume'] case final num value) {
        final volume = value.toDouble();
        if (volume != _targetVolume) {
          _targetVolume = volume;
          _selfVolumeUntil = nowUs + _selfVolumeUs;
          await UnisonNative.setVolume(volume);
        }
      }
    } catch (_) {}
    _report();
  }

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
    });
  }
}
