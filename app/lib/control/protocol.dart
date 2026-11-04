import 'dart:convert';

typedef Message = Map<String, dynamic>;

abstract final class Protocol {
  /// 发现用的 UDP 端口（音频占用 47800/47801）
  static const discoveryPort = 47810;

  /// 音源优先使用的控制端口，控制台可不经发现直接连接上次的音源
  static const controlPort = 47811;

  /// 区分本应用的报文
  static const app = 'unison';

  /// 控制协议版本，两端不同时不建立连接
  static const version = 1;

  static String encode(Map<String, Object?> message) => jsonEncode(message);

  static Message? decode(String text) {
    try {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) return value;
    } catch (_) {}
    return null;
  }
}

/// UDP 报文类型（字段 `k`）
abstract final class Datagram {
  /// 音源广播自身的控制端口
  static const beacon = 'beacon';

  /// 控制台寻找音源，音源以 [beacon] 单播回应
  static const probe = 'probe';
}

/// 控制连接上的消息类型（字段 `t`）
abstract final class MessageType {
  /// 时钟校准请求与回应，也用于确认连接存活
  static const ping = 'ping';
  static const pong = 'pong';

  /// 设备 → 音源：连接后的第一条消息，带协议版本与设备信息
  static const hello = 'hello';

  /// 音源 → 设备：协议版本不同，随后断开
  static const incompatible = 'incompatible';

  /// 音源 → 设备：控制台的全部状态
  static const state = 'state';

  /// 音源 → 设备：本机应处的接收状态、偏移与音量
  static const apply = 'apply';

  /// 设备 → 音源：本机接收状态、统计与实际音量
  static const report = 'report';

  /// 设备 → 音源：用户在本机调整了音量（如按音量键）
  static const localVolume = 'localVolume';

  /// 设备 → 音源：控制台操作（字段 `c` 见 [Command]）
  static const command = 'cmd';
}

/// 控制台操作（字段 `c`）
abstract final class Command {
  static const media = 'media';
  static const seek = 'seek';
  static const source = 'source';
  static const latency = 'latency';
  static const localDelay = 'localDelay';
  static const offset = 'offset';
  static const volume = 'volume';
  static const volumeMode = 'volumeMode';
  static const receive = 'receive';
  static const calibrate = 'calibrate';
  static const calibrateCancel = 'calibrateCancel';
  static const calibrateUndo = 'calibrateUndo';
  static const calibrateClose = 'calibrateClose';
  static const bandWeight = 'bandWeight';
}
