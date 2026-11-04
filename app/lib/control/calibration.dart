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
    required this.localDelayUs,
    required this.baseOffsets,
    required this.localGaps,
    required this.gaps,
    required this.missing,
  });

  final int localDelayUs;

  /// 各设备按中高频对齐的偏移（不含按频段的平移）
  final Map<String, int> baseOffsets;
  final BandGaps localGaps;

  /// 本次测得中高频的设备的低频记录
  final Map<String, BandGaps> gaps;

  /// 未测得中高频的设备，偏移只随本机延迟的变化平移
  final Set<String> missing;
}

/// 把测量换算为设置。测量在当前设置下进行：本机到达 L 已含本机延迟，接收端到达 R
/// 已含其当前生效的偏移 e，故使其与本机对齐的偏移为 e + (L − R)。接收端不能比目标
/// 延迟更早发声（偏移不小于 0），需要时推迟本机；各偏移都大于 0 时先减少本机延迟
///
/// [effective] 为参与校准的设备当前生效的偏移；[bases] 为所有已知设备的中高频偏移
CalibrationOutcome solveCalibration({
  required int localDelayUs,
  required Map<String, int> effective,
  required Map<String, int> bases,
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
  final lowest = aligned.values.reduce((a, b) => a < b ? a : b);
  // 本机延迟的变化量：为正时推迟本机，各偏移随之增加同样的量
  final shift = lowest < 0 ? -lowest : -(lowest < localDelayUs ? lowest : localDelayUs);
  return CalibrationOutcome(
    localDelayUs: localDelayUs + shift,
    baseOffsets: {
      for (final MapEntry(key: id, value: base) in bases.entries) id: base + shift,
      for (final MapEntry(key: id, value: offset) in aligned.entries) id: offset + shift,
    },
    localGaps: gapsOf(local),
    gaps: gaps,
    missing: missing,
  );
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
