import 'dart:math';

import 'package:unison_native/unison_native.dart';

import 'models.dart';

/// 中高频之外按此顺序找共同频段
const _lowBands = [CalibrationBand.bass, CalibrationBand.lowMid];

String bandLabel(CalibrationBand band) => switch (band) {
  CalibrationBand.midHigh => '中高频',
  CalibrationBand.lowMid => '中低频',
  CalibrationBand.bass => '低音',
};

int? _arrival(List<BandMeasurement> measurements, CalibrationBand band) {
  for (final m in measurements) {
    if (m.band == band) return m.arrivalUs;
  }
  return null;
}

/// 各低频频段相对中高频额外的延迟；中高频未测得时为空
BandGaps gapsOf(List<BandMeasurement> measurements) {
  final mid = _arrival(measurements, CalibrationBand.midHigh);
  if (mid == null) return {};
  return {
    for (final band in _lowBands)
      if (_arrival(measurements, band) case final arrival?) band: arrival - mid,
  };
}

/// 两台设备都可靠测得的低频频段，优先低音；没有时为 null
CalibrationBand? commonBand(BandGaps a, BandGaps b) {
  for (final band in _lowBands) {
    if (a.containsKey(band) && b.containsKey(band)) return band;
  }
  return null;
}

/// 接收端在对齐位置 [weight] 下的偏移平移：按与本机共同的低频频段，低频比本机
/// 晚 Δ 时提前 weight·Δ；没有共同频段时为 0
int bandShift(double weight, BandGaps device, BandGaps local) {
  final band = commonBand(device, local);
  if (band == null) return 0;
  return (-weight * (device[band]! - local[band]!)).round();
}

/// 输出通道的简称：大缓冲、主输出有明确含义，其余直接用原始标志名。通道以输出 flags 标识
/// （如 `PRIMARY|FAST`）
String channelLabel(String channel) {
  final flags = channel.split('|').toSet();
  if (flags.contains('DEEP_BUFFER')) return '大缓冲';
  if (flags.contains('PRIMARY')) return '主输出';
  return channel;
}

/// 输出通道的完整名称：有简称时附上原始标志名
String channelName(String channel) {
  final label = channelLabel(channel);
  return label == channel ? channel : '$label（$channel）';
}

/// 会话所在通道及其校准状态的说明
String sessionChannel(SessionView session) => switch (session.channel) {
  null => '输出通道未知，未补偿',
  final channel when !session.calibrated => '输出通道 ${channelName(channel)} 未校准，未补偿',
  final channel => '输出通道 ${channelName(channel)}',
};

/// 本机一条输出通道的实测：取样点到发声的延迟 [midUs]（中高频，不含本机延迟）与低频记录
class ChannelLatency {
  const ChannelLatency({required this.midUs, required this.gaps});

  final int midUs;
  final BandGaps gaps;

  Map<String, Object?> toJson() => {'midUs': midUs, 'gaps': gapsToJson(gaps)};

  static ChannelLatency? fromJson(Object? json) => switch (json) {
    {'midUs': final num mid} => ChannelLatency(midUs: mid.toInt(), gaps: gapsFromJson(json['gaps'])),
    _ => null,
  };
}

/// 已校准的输出通道
typedef Channels = Map<String, ChannelLatency>;

Map<String, Object?> channelsToJson(Channels channels) => {
  for (final MapEntry(:key, :value) in channels.entries) key: value.toJson(),
};

Channels channelsFromJson(Object? json) {
  if (json is! Map) return {};
  return {
    for (final MapEntry(:key, :value) in json.entries)
      if (ChannelLatency.fromJson(value) case final channel? when key is String) key: channel,
  };
}

/// 基准通道：已校准通道中出声最慢的；没有时为 null
String? baseChannel(Channels channels) {
  String? base;
  for (final MapEntry(:key, :value) in channels.entries) {
    if (base == null || value.midUs > channels[base]!.midUs) base = key;
  }
  return base;
}

/// 本机按基准通道发声，接收端与之对齐时所用的低频记录
BandGaps localGapsOf(Channels channels) => channels[baseChannel(channels)]?.gaps ?? const {};

/// 各已校准通道在对齐位置 [weight] 下追加的延迟，使其与基准通道同时发声：通道 p 的对齐到达时间
/// 为 mid_p + weight·gap_p（gap 取与基准通道共同测得的低频频段，没有时只按中高频），追加量为
/// 基准与之的差，不小于 0
Map<String, int> channelDelays(Channels channels, double weight) {
  final base = channels[baseChannel(channels)];
  if (base == null) return {};
  int delay(ChannelLatency channel) {
    final band = commonBand(channel.gaps, base.gaps);
    final lead = base.midUs - channel.midUs + (band == null ? 0 : weight * (base.gaps[band]! - channel.gaps[band]!));
    return max(0, lead.round());
  }

  return {for (final MapEntry(:key, :value) in channels.entries) key: delay(value)};
}

/// 校准换算的结果
class CalibrationOutcome {
  const CalibrationOutcome({
    required this.baseOffsets,
    required this.channels,
    required this.unmeasured,
    required this.gaps,
    required this.missing,
  });

  /// 测得中高频的设备按中高频与本机基准通道对齐的偏移（不含按频段的平移）
  final Map<String, int> baseOffsets;

  /// 测得中高频的本机通道
  final Channels channels;

  /// 测过但未测得中高频的本机通道
  final Set<String> unmeasured;

  /// 测得中高频的设备的低频记录
  final Map<String, BandGaps> gaps;

  /// 未测得中高频的设备，设置不变
  final Set<String> missing;
}

/// 把测量换算为通道延迟与偏移。测量在开始时的设置下进行，测试音不含通道补偿：本机各通道的
/// 到达已含本机延迟 [localDelayUs]；接收端到达 R 已含其当时生效的偏移 e。播放时本机各通道补偿到
/// 基准通道，故以基准通道的到达 L 对齐，偏移为 e + (L − R)。本机延迟由之后的
/// [normalizationShift] 统一调整
CalibrationOutcome solveCalibration({
  required Map<String, int> effective,
  required int localDelayUs,
  required Map<String, List<BandMeasurement>> local,
  required Map<String, List<BandMeasurement>> receivers,
}) {
  final channels = <String, ChannelLatency>{};
  final unmeasured = <String>{};
  for (final MapEntry(key: channel, value: measurements) in local.entries) {
    final arrival = _arrival(measurements, CalibrationBand.midHigh);
    if (arrival == null) {
      unmeasured.add(channel);
    } else {
      channels[channel] = ChannelLatency(midUs: arrival - localDelayUs, gaps: gapsOf(measurements));
    }
  }
  final base = channels[baseChannel(channels)];
  if (base == null) throw const CalibrationFailure('本机未测到测试音');
  final localArrival = base.midUs + localDelayUs;
  final aligned = <String, int>{};
  final missing = <String>{};
  final gaps = <String, BandGaps>{};
  for (final MapEntry(key: id, value: measurements) in receivers.entries) {
    final arrival = _arrival(measurements, CalibrationBand.midHigh);
    if (arrival == null) {
      missing.add(id);
      continue;
    }
    aligned[id] = (effective[id] ?? 0) + localArrival - arrival;
    gaps[id] = gapsOf(measurements);
  }
  if (aligned.isEmpty) throw const CalibrationFailure('未测到任何接收端的测试音');
  return CalibrationOutcome(baseOffsets: aligned, channels: channels, unmeasured: unmeasured, gaps: gaps, missing: missing);
}

/// 本机延迟与所有偏移同加的量，使各生效偏移都不小于 0（接收端不早于目标延迟发声）
/// 且本机延迟尽量小：有偏移为负时推迟本机，各偏移都为正时先减少本机延迟
int normalizationShift(int localDelayUs, Iterable<int> effective) {
  if (effective.isEmpty) return 0;
  final lowest = effective.reduce(min);
  if (lowest < 0) return -lowest;
  return -min(lowest, localDelayUs);
}

class CalibrationFailure implements Exception {
  const CalibrationFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 偏移的文本：正值（更晚发声）为「慢」，负值为「快」，精确到 0.1ms
String formatOffset(int us) {
  final tenths = (us.abs() / 100).round();
  if (tenths == 0) return '0 ms';
  return '${us > 0 ? '慢' : '快'} ${(tenths / 10).toStringAsFixed(1)} ms';
}

/// 对齐频段位置的文本
String bandPosition(double weight) => switch (weight) {
  0.0 => '中高频',
  1.0 => '低频',
  _ => '低频 ${(weight * 100).round()}%',
};

String formatMs(int us) => '${(us / 1000).toStringAsFixed(1)} ms';

/// 低频相对本机的差值说明
String bandNote(BandGaps device, BandGaps local) {
  final band = commonBand(device, local);
  if (band == null) return '没有与本机都测得的低频段，按中高频';
  final gap = device[band]! - local[band]!;
  return '${bandLabel(band)}比本机${gap < 0 ? '早' : '晚'} ${formatMs(gap.abs())}';
}
