import 'package:unison_native/unison_native.dart';

enum DevicePlatform {
  android('Android'),
  windows('Windows');

  const DevicePlatform(this.label);

  final String label;
}

enum VolumeMode {
  follow('跟随音源'),
  independent('独立');

  const VolumeMode(this.label);

  final String label;
}

/// 接收端的音量设置，保存在音源上
class VolumeSetting {
  const VolumeSetting({required this.mode, required this.offset, required this.level});

  static const initial = VolumeSetting(mode: VolumeMode.follow, offset: 0, level: 0.5);

  final VolumeMode mode;

  /// 跟随音源时相对音源音量的偏移（百分点）
  final int offset;

  /// 独立时设定的音量（0~1）
  final double level;

  /// 应设定的音量；跟随音源而音源音量未知时为 null
  double? target(double? sourceVolume) => switch (mode) {
    VolumeMode.follow =>
      sourceVolume == null ? null : (sourceVolume + offset / 100).clamp(0.0, 1.0).toDouble(),
    VolumeMode.independent => level,
  };

  /// 把设备音量设为 [volume]：跟随时折算为偏移，独立时为设定值
  VolumeSetting withVolume(double volume, double? sourceVolume) => switch (mode) {
    VolumeMode.follow =>
      sourceVolume == null ? this : copyWith(offset: ((volume - sourceVolume) * 100).round()),
    VolumeMode.independent => copyWith(level: volume.clamp(0.0, 1.0).toDouble()),
  };

  /// 切换模式，保持设备当前的音量 [actual] 不变
  VolumeSetting switchTo(VolumeMode value, double? actual, double? sourceVolume) =>
      actual == null ? copyWith(mode: value) : copyWith(mode: value).withVolume(actual, sourceVolume);

  VolumeSetting copyWith({VolumeMode? mode, int? offset, double? level}) => VolumeSetting(
    mode: mode ?? this.mode,
    offset: offset ?? this.offset,
    level: level ?? this.level,
  );

  Map<String, Object?> toJson() => {'mode': mode.name, 'offset': offset, 'level': level};

  static VolumeSetting fromJson(Object? json) {
    if (json is! Map) return initial;
    return VolumeSetting(
      mode: VolumeMode.values.asNameMap()[json['mode']] ?? VolumeMode.follow,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// 各低频频段相对中高频额外的延迟（微秒），只含两段都测得的频段
typedef BandGaps = Map<CalibrationBand, int>;

Map<String, Object?> gapsToJson(BandGaps gaps) => {
  for (final MapEntry(key: band, value: gap) in gaps.entries) band.name: gap,
};

BandGaps gapsFromJson(Object? json) {
  if (json is! Map) return {};
  final bands = CalibrationBand.values.asNameMap();
  return {
    for (final MapEntry(:key, :value) in json.entries)
      if (bands[key] case final band? when value is num) band: value.toInt(),
  };
}

Map<String, Object?> statsToJson(ReceiverStats s) => {
  'running': s.running,
  'sourceHost': s.sourceHost,
  'clockReady': s.clockReady,
  'syncErrorUs': s.syncErrorUs,
  'bufferUs': s.bufferUs,
  'rttUs': s.rttUs,
  'lostPackets': s.lostPackets,
  'latePackets': s.latePackets,
  'xruns': s.xruns,
  'speedPpm': s.speedPpm,
  'realTimestamp': s.realTimestamp,
  'outputDevice': s.outputDevice,
};

ReceiverStats? statsFromJson(Object? json) {
  if (json is! Map) return null;
  int i(String key) => (json[key] as num?)?.toInt() ?? 0;
  return ReceiverStats(
    running: json['running'] == true,
    sourceHost: json['sourceHost'] as String?,
    clockReady: json['clockReady'] == true,
    syncErrorUs: i('syncErrorUs'),
    bufferUs: i('bufferUs'),
    rttUs: i('rttUs'),
    lostPackets: i('lostPackets'),
    latePackets: i('latePackets'),
    xruns: i('xruns'),
    speedPpm: (json['speedPpm'] as num?)?.toDouble() ?? 0,
    realTimestamp: json['realTimestamp'] == true,
    outputDevice: json['outputDevice'] as String? ?? '',
  );
}

/// 控制台列出的一台设备
class DeviceView {
  const DeviceView({
    required this.id,
    required this.name,
    required this.platform,
    required this.isSource,
    required this.online,
    required this.receive,
    required this.receiving,
    required this.offsetUs,
    required this.volume,
    required this.actualVolume,
    required this.stats,
  });

  final String id;
  final String name;
  final DevicePlatform platform;

  /// 音源设备本身（不接收，没有偏移）
  final bool isSource;
  final bool online;

  /// 设定为接收音频
  final bool receive;

  /// 音源正向其发送音频
  final bool receiving;

  /// 当前生效的偏移（含按频段对齐的平移），正值更晚发声
  final int offsetUs;
  final VolumeSetting volume;
  final double? actualVolume;
  final ReceiverStats? stats;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'platform': platform.name,
    'isSource': isSource,
    'online': online,
    'receive': receive,
    'receiving': receiving,
    'offsetUs': offsetUs,
    'volume': volume.toJson(),
    'actualVolume': actualVolume,
    'stats': stats == null ? null : statsToJson(stats!),
  };

  static DeviceView fromJson(Map json) => DeviceView(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    platform: DevicePlatform.values.asNameMap()[json['platform']] ?? DevicePlatform.android,
    isSource: json['isSource'] == true,
    online: json['online'] == true,
    receive: json['receive'] == true,
    receiving: json['receiving'] == true,
    offsetUs: (json['offsetUs'] as num?)?.toInt() ?? 0,
    volume: VolumeSetting.fromJson(json['volume']),
    actualVolume: (json['actualVolume'] as num?)?.toDouble(),
    stats: statsFromJson(json['stats']),
  );
}

class SourceView {
  const SourceView({
    required this.running,
    required this.latencyUs,
    required this.localDelayUs,
    required this.error,
    required this.sessions,
  });

  final bool running;
  final int latencyUs;
  final int localDelayUs;
  final String? error;

  /// 正在采集的播放会话（应用包名）
  final List<String> sessions;

  Map<String, Object?> toJson() => {
    'running': running,
    'latencyUs': latencyUs,
    'localDelayUs': localDelayUs,
    'error': error,
    'sessions': sessions,
  };

  static SourceView fromJson(Map json) => SourceView(
    running: json['running'] == true,
    latencyUs: (json['latencyUs'] as num?)?.toInt() ?? 0,
    localDelayUs: (json['localDelayUs'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
    sessions: [...?(json['sessions'] as List?)?.cast<String>()],
  );
}

/// 音源设备上的媒体会话；[positionAtUs] 为音源时钟
class MediaView {
  const MediaView({
    required this.packageName,
    required this.title,
    required this.artist,
    required this.durationUs,
    required this.positionUs,
    required this.positionAtUs,
    required this.speed,
    required this.playing,
    required this.canSeek,
  });

  factory MediaView.of(MediaState s) => MediaView(
    packageName: s.packageName,
    title: s.title,
    artist: s.artist,
    durationUs: s.durationUs,
    positionUs: s.positionUs,
    positionAtUs: s.positionUpdatedAtUs,
    speed: s.speed,
    playing: s.playing,
    canSeek: s.canSeek,
  );

  final String packageName;
  final String? title;
  final String? artist;
  final int? durationUs;
  final int positionUs;
  final int positionAtUs;
  final double speed;
  final bool playing;
  final bool canSeek;

  Map<String, Object?> toJson() => {
    'packageName': packageName,
    'title': title,
    'artist': artist,
    'durationUs': durationUs,
    'positionUs': positionUs,
    'positionAtUs': positionAtUs,
    'speed': speed,
    'playing': playing,
    'canSeek': canSeek,
  };

  static MediaView fromJson(Map json) => MediaView(
    packageName: json['packageName'] as String? ?? '',
    title: json['title'] as String?,
    artist: json['artist'] as String?,
    durationUs: (json['durationUs'] as num?)?.toInt(),
    positionUs: (json['positionUs'] as num?)?.toInt() ?? 0,
    positionAtUs: (json['positionAtUs'] as num?)?.toInt() ?? 0,
    speed: (json['speed'] as num?)?.toDouble() ?? 1,
    playing: json['playing'] == true,
    canSeek: json['canSeek'] == true,
  );
}

enum CalibrationStage { idle, running, done, failed }

/// 校准结果中的一行
class CalibrationRow {
  const CalibrationRow({required this.name, required this.result, this.detail});

  final String name;
  final String result;
  final String? detail;

  Map<String, Object?> toJson() => {'name': name, 'result': result, 'detail': detail};

  static CalibrationRow fromJson(Map json) => CalibrationRow(
    name: json['name'] as String? ?? '',
    result: json['result'] as String? ?? '',
    detail: json['detail'] as String?,
  );
}

class CalibrationView {
  const CalibrationView({
    this.stage = CalibrationStage.idle,
    this.step = 0,
    this.totalSteps = 0,
    this.description = '',
    this.message,
    this.rows = const [],
    this.canUndo = false,
  });

  final CalibrationStage stage;
  final int step;
  final int totalSteps;
  final String description;
  final String? message;
  final List<CalibrationRow> rows;
  final bool canUndo;

  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'step': step,
    'totalSteps': totalSteps,
    'description': description,
    'message': message,
    'rows': [for (final row in rows) row.toJson()],
    'canUndo': canUndo,
  };

  static CalibrationView fromJson(Map json) => CalibrationView(
    stage: CalibrationStage.values.asNameMap()[json['stage']] ?? CalibrationStage.idle,
    step: (json['step'] as num?)?.toInt() ?? 0,
    totalSteps: (json['totalSteps'] as num?)?.toInt() ?? 0,
    description: json['description'] as String? ?? '',
    message: json['message'] as String?,
    rows: [for (final row in (json['rows'] as List? ?? const [])) CalibrationRow.fromJson(row as Map)],
    canUndo: json['canUndo'] == true,
  );
}

/// 按频段对齐：[weight] 0 为按中高频，1 为按低频
class BandView {
  const BandView({required this.weight, required this.available, required this.notes});

  final double weight;

  /// 有低频实测数据，滑块可用
  final bool available;

  /// 本机与各接收端的低频实测说明
  final List<String> notes;

  Map<String, Object?> toJson() => {'weight': weight, 'available': available, 'notes': notes};

  static BandView fromJson(Map json) => BandView(
    weight: (json['weight'] as num?)?.toDouble() ?? 0,
    available: json['available'] == true,
    notes: [...?(json['notes'] as List?)?.cast<String>()],
  );
}

/// 控制台显示的全部状态，由音源维护并同步到各设备
class ConsoleState {
  const ConsoleState({
    required this.sourceId,
    required this.source,
    required this.media,
    required this.devices,
    required this.calibration,
    required this.band,
    required this.boost,
    required this.sentAtUs,
  });

  final String sourceId;
  final SourceView source;
  final MediaView? media;

  /// 音源设备在前，其余按名称
  final List<DeviceView> devices;
  final CalibrationView calibration;
  final BandView band;

  /// 校准时临时提高到的音量，关闭时为 null
  final double? boost;

  /// 生成此状态时的音源时刻
  final int sentAtUs;

  DeviceView? device(String id) {
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'source': source.toJson(),
    'media': media?.toJson(),
    'devices': [for (final device in devices) device.toJson()],
    'calibration': calibration.toJson(),
    'band': band.toJson(),
    'boost': boost,
    'sentAtUs': sentAtUs,
  };

  static ConsoleState? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return ConsoleState(
        sourceId: json['sourceId'] as String,
        source: SourceView.fromJson(json['source'] as Map),
        media: json['media'] == null ? null : MediaView.fromJson(json['media'] as Map),
        devices: [for (final d in json['devices'] as List) DeviceView.fromJson(d as Map)],
        calibration: CalibrationView.fromJson(json['calibration'] as Map),
        band: BandView.fromJson(json['band'] as Map),
        boost: (json['boost'] as num?)?.toDouble(),
        sentAtUs: (json['sentAtUs'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}
