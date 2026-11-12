import 'package:flutter_test/flutter_test.dart';
import 'package:unison/control/calibration.dart';
import 'package:unison_native/unison_native.dart';

List<BandMeasurement> _m(int? mid, {int? bass}) => [
  BandMeasurement(band: CalibrationBand.midHigh, arrivalUs: mid, spreadUs: 0, rounds: 3),
  BandMeasurement(band: CalibrationBand.bass, arrivalUs: bass, spreadUs: 0, rounds: 3),
];

void main() {
  test('按本机最慢的通道换算各接收端的偏移与各通道的补偿', () {
    final outcome = solveCalibration(
      effective: {'a': 1000, 'b': 0, 'c': 0},
      localDelayUs: 2000,
      local: {'DEEP_BUFFER': _m(150000, bass: 153000), 'PRIMARY|FAST': _m(60000, bass: 64000), 'DIRECT': _m(null)},
      receivers: {'a': _m(148000, bass: 152000), 'b': _m(152000), 'c': _m(null)},
    );
    // 以大缓冲（150000）对齐：a：1000 + 150000 − 148000；b：0 + 150000 − 152000
    expect(outcome.baseOffsets, {'a': 3000, 'b': -2000});
    expect(outcome.missing, {'c'});
    expect(outcome.unmeasured, {'DIRECT'});
    expect(outcome.channels['DEEP_BUFFER']!.midUs, 148000);
    expect(outcome.channels['PRIMARY|FAST']!.midUs, 58000);
    expect(localGapsOf(outcome.channels), {CalibrationBand.bass: 3000});
    expect(bandShift(1, outcome.gaps['a']!, localGapsOf(outcome.channels)), -1000);
    // 中高频差 90ms；按低频时主输出低音比基准晚 1ms，少补 1ms
    expect(channelDelays(outcome.channels, 0), {'DEEP_BUFFER': 0, 'PRIMARY|FAST': 90000});
    expect(channelDelays(outcome.channels, 1), {'DEEP_BUFFER': 0, 'PRIMARY|FAST': 89000});
  });

  test('没有共同低频段时只按中高频补偿，补偿不小于 0', () {
    const channels = {
      'DEEP_BUFFER': ChannelLatency(midUs: 100000, gaps: {CalibrationBand.bass: 1000}),
      'PRIMARY|FAST': ChannelLatency(midUs: 40000, gaps: {CalibrationBand.lowMid: 5000}),
      'FAST': ChannelLatency(midUs: 99000, gaps: {CalibrationBand.bass: 50000}),
    };
    expect(baseChannel(channels), 'DEEP_BUFFER');
    expect(channelDelays(channels, 1), {'DEEP_BUFFER': 0, 'PRIMARY|FAST': 60000, 'FAST': 0});
    expect(channelDelays(channels, 0.5), {'DEEP_BUFFER': 0, 'PRIMARY|FAST': 60000, 'FAST': 0});
    expect(channelDelays(channels, 0)['FAST'], 1000);
  });

  test('偏移为负时推迟本机，都为正时先减少本机延迟，含未参与的设备', () {
    expect(normalizationShift(0, [3000, -2000, 500]), 2000);
    expect(normalizationShift(3000, [5000, 2000]), -2000);
    expect(normalizationShift(1000, [5000, 2000]), -1000);
    expect(normalizationShift(1000, [0, 2000]), 0);
    expect(normalizationShift(1000, []), 0);
  });

  test('连续按增量调早偏移，本机延迟按实际调节量增加', () {
    var localDelay = 0;
    final offsets = {'a': 0, 'b': 2000};
    for (var i = 0; i < 3; i++) {
      offsets['a'] = offsets['a']! - 500;
      final shift = normalizationShift(localDelay, offsets.values);
      localDelay += shift;
      offsets.updateAll((_, offset) => offset + shift);
    }
    expect(localDelay, 1500);
    expect(offsets, {'a': 0, 'b': 3500});
  });
}
