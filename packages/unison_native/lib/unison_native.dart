/// Unison 原生能力的 Dart 接口：界面与控制逻辑（app/）只通过本文件使用原生能力。
///
/// 时间单位一律为微秒；音量为 0~1。各平台不支持的能力调用时抛出 [UnsupportedError]
/// （例如 Windows 上的音源、媒体控制）。
library;

import 'dart:async';

/// 接收端统计（约每秒 4 次）。
class ReceiverStats {
  const ReceiverStats({
    required this.running,
    required this.sourceHost,
    required this.clockReady,
    required this.syncErrorUs,
    required this.bufferUs,
    required this.rttUs,
    required this.lostPackets,
    required this.latePackets,
    required this.xruns,
    required this.speedPpm,
    required this.realTimestamp,
    required this.outputDevice,
  });

  final bool running;

  /// 当前接收的音源地址，未连接时为 null
  final String? sourceHost;
  final bool clockReady;
  final int syncErrorUs;
  final int bufferUs;
  final int rttUs;
  final int lostPackets;
  final int latePackets;
  final int xruns;
  final double speedPpm;
  final bool realTimestamp;

  /// 实际输出设备名
  final String outputDevice;
}

/// 音源端正在采集的一个播放会话。
class CapturedSession {
  const CapturedSession({required this.uid, required this.packageName, required this.sessionId});

  final int uid;
  final String? packageName;
  final int sessionId;
}

/// 音源端状态（变化时推送，运行中至少每秒一次）。
class SourceStatus {
  const SourceStatus({
    required this.running,
    required this.latencyUs,
    required this.localDelayUs,
    required this.sessions,
    required this.receiverIds,
    this.error,
  });

  final bool running;

  /// 目标延迟：接收端在"混音时刻 + latencyUs"发声
  final int latencyUs;

  /// 本机延迟：音源本机输出额外推迟的时间
  final int localDelayUs;
  final List<CapturedSession> sessions;

  /// 当前订阅音频的接收端 id（与 [UnisonNative.receiverId] 对应）
  final List<int> receiverIds;

  /// 音源进程失败退出的原因（之后 running 为 false）
  final String? error;
}

/// 声学校准频段。
enum CalibrationBand { midHigh, lowMid, bass }

/// 一台设备在一个频段的测量：测试音到达音源麦克风的时刻相对混音时刻的延迟。
class BandMeasurement {
  const BandMeasurement({required this.band, required this.arrivalUs, required this.spreadUs, required this.rounds});

  final CalibrationBand band;

  /// 多轮中位数；不可靠时为 null
  final int? arrivalUs;

  /// 采用轮次的极差
  final int? spreadUs;

  /// 采用的轮数
  final int rounds;
}

/// 一次校准的测量结果；如何换算成目标延迟/本机延迟/各接收端偏移由调用方决定。
class CalibrationResult {
  const CalibrationResult({required this.local, required this.receivers});

  /// 音源本机
  final List<BandMeasurement> local;

  /// 各接收端（键为 receiverId）
  final Map<int, List<BandMeasurement>> receivers;
}

/// 校准进度。
class CalibrationProgress {
  const CalibrationProgress({required this.step, required this.totalSteps, required this.description});

  final int step;
  final int totalSteps;
  final String description;
}

/// 音源设备上当前的媒体会话。
class MediaState {
  const MediaState({
    required this.packageName,
    required this.title,
    required this.artist,
    required this.durationUs,
    required this.positionUs,
    required this.positionUpdatedAtUs,
    required this.speed,
    required this.playing,
    required this.canSeek,
  });

  final String packageName;
  final String? title;
  final String? artist;
  final int? durationUs;
  final int positionUs;

  /// [positionUs] 对应的本机单调时刻（与 [UnisonNative.monotonicUs] 同一时钟）
  final int positionUpdatedAtUs;
  final double speed;
  final bool playing;
  final bool canSeek;
}

enum MediaCommand { play, pause, next, previous }

abstract final class UnisonNative {
  /// 本机单调时钟（微秒），与原生侧时间戳同一时钟
  static int get monotonicUs => throw UnimplementedError();

  // ---- 接收端（Android、Windows）----

  /// 本机接收端 id（进程内固定），音源端用它识别订阅者
  static Future<int> receiverId() => throw UnimplementedError();

  /// 开始接收 [sourceHost] 的音频；Android 上同时进入前台服务
  static Future<void> startReceiver({required String sourceHost}) => throw UnimplementedError();

  static Future<void> stopReceiver() => throw UnimplementedError();

  /// 本机偏移：正值更晚发声
  static Future<void> setReceiverOffsetUs(int offsetUs) => throw UnimplementedError();

  static Stream<ReceiverStats> get receiverStats => throw UnimplementedError();

  /// Windows：可选输出设备名列表；Android 抛出 UnsupportedError
  static Future<List<String>> outputDevices() => throw UnimplementedError();

  /// Windows：选择输出设备，null 表示跟随系统默认
  static Future<void> setOutputDevice(String? name) => throw UnimplementedError();

  // ---- 本机音量 ----

  /// Android：系统媒体音量；Windows：Unison 自身输出音量
  static Future<double> volume() => throw UnimplementedError();

  static Future<void> setVolume(double volume) => throw UnimplementedError();

  /// 音量变化（含用户按音量键）
  static Stream<double> get volumeChanges => throw UnimplementedError();

  // ---- 音源（仅已 root 的 Android）----

  /// root 可用且音效模块已生效
  static Future<bool> sourceAvailable() => throw UnimplementedError();

  /// 启动音源；Android 上同时进入前台服务
  static Future<void> startSource({required int latencyUs, required int localDelayUs}) =>
      throw UnimplementedError();

  static Future<void> stopSource() => throw UnimplementedError();

  static Future<void> setSourceLatencyUs(int latencyUs) => throw UnimplementedError();

  static Future<void> setLocalDelayUs(int localDelayUs) => throw UnimplementedError();

  static Stream<SourceStatus> get sourceStatus => throw UnimplementedError();

  /// 对 [receiverIds] 逐台与本机做声学测量；期间暂停转发正常音频。可用 [cancelCalibration] 中止
  static Future<CalibrationResult> calibrate({
    required List<int> receiverIds,
    required List<CalibrationBand> bands,
    required void Function(CalibrationProgress progress) onProgress,
  }) => throw UnimplementedError();

  static Future<void> cancelCalibration() => throw UnimplementedError();

  // ---- 媒体控制（音源设备上）----

  /// 当前媒体会话，无会话时为 null
  static Stream<MediaState?> get mediaState => throw UnimplementedError();

  static Future<void> mediaCommand(MediaCommand command) => throw UnimplementedError();

  static Future<void> mediaSeek(int positionUs) => throw UnimplementedError();
}
