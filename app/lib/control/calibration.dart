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

/// 校准换算的结果
class CalibrationOutcome {
  const CalibrationOutcome({
    required this.baseOffsets,
    required this.localGaps,
    required this.gaps,
    required this.missing,
  });

  /// 测得中高频的设备按中高频与本机对齐的偏移（不含按频段的平移）
  final Map<String, int> baseOffsets;
  final BandGaps localGaps;

  /// 测得中高频的设备的低频记录
  final Map<String, BandGaps> gaps;

  /// 未测得中高频的设备，设置不变
  final Set<String> missing;
}

/// 把测量换算为偏移。测量在开始时的设置下进行：本机到达 L 已含本机延迟，接收端
/// 到达 R 已含其当时生效的偏移 e，故使其与本机对齐的偏移为 e + (L − R)。本机延迟
/// 由之后的 [normalizationShift] 统一调整
CalibrationOutcome solveCalibration({
  required Map<String, int> effective,
  required List<BandMeasurement> local,
  required Map<String, List<BandMeasurement>> receivers,
}) {
  final localArrival = _arrival(local, CalibrationBand.midHigh);
  if (localArrival == null) throw const CalibrationFailure('本机未测到测试音');
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
  return CalibrationOutcome(baseOffsets: aligned, localGaps: gapsOf(local), gaps: gaps, missing: missing);
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

String formatMs(int us) => '${(us / 1000).toStringAsFixed(1)} ms';

/// 低频相对本机的差值说明
String bandNote(BandGaps device, BandGaps local) {
  final band = commonBand(device, local);
  if (band == null) return '没有与本机都测得的低频段，按中高频';
  final gap = device[band]! - local[band]!;
  return '${bandLabel(band)}比本机${gap < 0 ? '早' : '晚'} ${formatMs(gap.abs())}';
}
