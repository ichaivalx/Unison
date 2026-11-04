/// Unison 原生能力的 Dart 接口：界面与控制逻辑（app/）只通过本文件使用原生能力。
///
/// 时间单位一律为微秒；音量为 0~1。各平台不支持的能力调用时抛出 [UnsupportedError]
/// （例如 Windows 上的音源、媒体控制）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:flutter/services.dart';

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

/// Windows 播放设备；保存 id，name 仅用于显示。
class OutputDevice {
  const OutputDevice({required this.id, required this.name});
  final String id;
  final String name;
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
    required this.appName,
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

  /// 来源 App 的显示名称；无法读取时为包名。
  final String appName;
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
  static const _methods = MethodChannel('unison_native/methods');
  static final _events = const EventChannel('unison_native/events').receiveBroadcastStream().cast<Map>();
  static final _clock = ffi.DynamicLibrary.open(Platform.isAndroid ? 'libunison.so' : 'unison_native_plugin.dll')
      .lookupFunction<ffi.Int64 Function(), int Function()>('unison_monotonic_us');
  static int get monotonicUs => _clock();
  static Future<T> _call<T>(String method, [Object? args]) async {
    try { return (await _methods.invokeMethod<T>(method, args)) as T; }
    on PlatformException catch (e) { if (e.code == 'unsupported') throw UnsupportedError(e.message ?? method); rethrow; }
  }
  static final Map<String, dynamic> _latest = {};
  static int _streamListeners = 0;
  static const _transientEvents = {'calibration', 'exit'};
  static Stream<dynamic> _stream(String type) {
    if (!Platform.isAndroid && (type == 'source' || type == 'media' || type == 'calibration')) {
      throw UnsupportedError('Requires rooted Android');
    }
    return Stream<dynamic>.multi((controller) {
      if (_streamListeners++ == 0) _latest.clear();
      final subscription = _events.listen((event) {
        final tag = event['type'] as String;
        final raw = event['data'];
        final data = raw is String ? jsonDecode(raw) : raw;
        if (!_transientEvents.contains(tag)) _latest[tag] = data;
        if (tag == type) controller.add(data);
      }, onError: controller.addError);
      if (!_transientEvents.contains(type) && _latest.containsKey(type)) controller.add(_latest[type]);
      controller.onCancel = () {
        if (--_streamListeners == 0) _latest.clear();
        subscription.cancel();
      };
    }, isBroadcast: true);
  }
  static Future<int> receiverId() => _call<int>('receiverId');

  /// Android 音源和控制端均在前台调用并等待完成，之后可在后台启停采集/接收；断线重连时保持开启。
  /// Windows 无需常驻服务，此调用不执行操作。
  static Future<void> setKeepAlive(bool on) => _call<void>('setKeepAlive', on);

  /// Android 通知上的“退出”；不重放。原生停止采集、接收和常驻，调用方同步状态并关闭控制连接。
  static Stream<void> get exitRequests => _stream('exit').map<void>((_) {});

  static Future<void> startReceiver({required String sourceHost}) => _call<void>('startReceiver', {'sourceHost': sourceHost});
  static Future<void> stopReceiver() => _call<void>('stopReceiver');
  static Future<void> setReceiverOffsetUs(int offsetUs) => _call<void>('setReceiverOffsetUs', offsetUs);
  static Stream<ReceiverStats> get receiverStats => _stream('receiver').map((dynamic e) => ReceiverStats(
    running: e['running'] == true, sourceHost: (e['sourceHost'] as String?)?.isEmpty == true ? null : e['sourceHost'] as String?, clockReady: e['clockReady'] == true,
    syncErrorUs: (e['syncErrorUs'] as num?)?.round() ?? 0, bufferUs: (e['bufferUs'] as num?)?.round() ?? 0,
    rttUs: (e['rttUs'] as num?)?.round() ?? 0, lostPackets: (e['lostPackets'] as num?)?.toInt() ?? 0,
    latePackets: (e['latePackets'] as num?)?.toInt() ?? 0, xruns: (e['xruns'] as num?)?.toInt() ?? 0,
    speedPpm: (e['speedPpm'] as num?)?.toDouble() ?? 0, realTimestamp: e['realTimestamp'] == true,
    outputDevice: e['outputDevice'] as String? ?? ''));
  static Future<List<OutputDevice>> outputDevices() async => (await _call<List<Object?>>('outputDevices'))
      .map((e) { final value = e as Map; return OutputDevice(id: value['id'] as String, name: value['name'] as String); }).toList();
  /// null 跟随系统默认；指定设备离线时临时使用默认设备，重连后自动切回。
  static Future<void> setOutputDevice(String? id) => _call<void>('setOutputDevice', id);
  static Future<double> volume() async => (await _call<num>('volume')).toDouble();
  static Future<void> setVolume(double volume) => _call<void>('setVolume', volume);
  static Stream<double> get volumeChanges => _stream('volume').map((dynamic e) => (e as num).toDouble());
  static Future<bool> sourceAvailable() => _call<bool>('sourceAvailable');
  static Future<void> startSource({required int latencyUs, required int localDelayUs}) =>
      _call<void>('startSource', {'latencyUs': latencyUs, 'localDelayUs': localDelayUs});
  static Future<void> stopSource() => _call<void>('stopSource');
  static Future<void> setSourceLatencyUs(int latencyUs) => _call<void>('setSourceLatencyUs', latencyUs);
  static Future<void> setLocalDelayUs(int localDelayUs) => _call<void>('setLocalDelayUs', localDelayUs);
  static Stream<SourceStatus> get sourceStatus => _stream('source').map((dynamic e) => SourceStatus(
    running: e['running'] == true, latencyUs: (e['latencyUs'] as num?)?.toInt() ?? 50000,
    localDelayUs: (e['localDelayUs'] as num?)?.toInt() ?? 0,
    sessions: ((e['sessions'] as List?) ?? []).map((dynamic s) => CapturedSession(uid: (s['uid'] as num).toInt(),
      packageName: s['packageName'] as String?, sessionId: (s['sessionId'] as num).toInt())).toList(),
    receiverIds: ((e['receiverIds'] as List?) ?? []).cast<int>(), error: e['error'] as String?));
  static Future<CalibrationResult> calibrate({required List<int> receiverIds, required List<CalibrationBand> bands,
    required void Function(CalibrationProgress progress) onProgress}) async {
    final subscription = _stream('calibration').listen((dynamic e) => onProgress(CalibrationProgress(
      step: (e['step'] as num).toInt(), totalSteps: (e['totalSteps'] as num).toInt(), description: e['description'] as String)));
    try {
      final result = await _call<Map<Object?, Object?>>('calibrate', {'receiverIds': receiverIds, 'bands': bands.map((b) => b.name).toList()});
      List<BandMeasurement> measurements(dynamic rows) => (rows as List).map((dynamic m) => BandMeasurement(
        band: CalibrationBand.values.byName(m['band'] as String), arrivalUs: (m['arrivalUs'] as num?)?.toInt(),
        spreadUs: (m['spreadUs'] as num?)?.toInt(), rounds: (m['rounds'] as num).toInt())).toList();
      return CalibrationResult(local: measurements(result['local']), receivers: {
        for (final entry in (result['receivers'] as Map).entries) int.parse(entry.key.toString()): measurements(entry.value)});
    } finally { await subscription.cancel(); }
  }
  static Future<void> cancelCalibration() => _call<void>('cancelCalibration');
  static Stream<MediaState?> get mediaState => _stream('media').map((dynamic e) => e == null ? null : MediaState(
    packageName: e['packageName'] as String, appName: e['appName'] as String, title: e['title'] as String?, artist: e['artist'] as String?,
    durationUs: (e['durationUs'] as num?)?.toInt(), positionUs: (e['positionUs'] as num).toInt(),
    positionUpdatedAtUs: (e['positionUpdatedAtUs'] as num).toInt(), speed: (e['speed'] as num).toDouble(),
    playing: e['playing'] == true, canSeek: e['canSeek'] == true));
  static Future<void> mediaCommand(MediaCommand command) => _call<void>('mediaCommand', command.name);
  static Future<void> mediaSeek(int positionUs) => _call<void>('mediaSeek', positionUs);
}
