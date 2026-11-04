import 'package:flutter_test/flutter_test.dart';
import 'package:unison/control/calibration.dart';
import 'package:unison_native/unison_native.dart';

List<BandMeasurement> _m(int? mid, {int? bass}) => [
  BandMeasurement(band: CalibrationBand.midHigh, arrivalUs: mid, spreadUs: 0, rounds: 3),
  BandMeasurement(band: CalibrationBand.bass, arrivalUs: bass, spreadUs: 0, rounds: 3),
];

void main() {
  test('按测量换算各接收端与本机对齐的偏移', () {
    final outcome = solveCalibration(
      effective: {'a': 1000, 'b': 0, 'c': 0},
      local: _m(30000, bass: 33000),
      receivers: {'a': _m(28000, bass: 32000), 'b': _m(32000), 'c': _m(null)},
    );
    // a：1000 + 30000 − 28000；b：0 + 30000 − 32000
    expect(outcome.baseOffsets, {'a': 3000, 'b': -2000});
    expect(outcome.missing, {'c'});
    expect(outcome.gaps['a'], {CalibrationBand.bass: 4000});
    expect(outcome.localGaps, {CalibrationBand.bass: 3000});
    expect(bandShift(1, outcome.gaps['a']!, outcome.localGaps), -1000);
    expect(bandShift(1, outcome.gaps['b']!, outcome.localGaps), 0);
  });

  test('偏移为负时推迟本机，都为正时先减少本机延迟，含未参与的设备', () {
    expect(normalizationShift(0, [3000, -2000, 500]), 2000);
    expect(normalizationShift(3000, [5000, 2000]), -2000);
    expect(normalizationShift(1000, [5000, 2000]), -1000);
    expect(normalizationShift(1000, [0, 2000]), 0);
    expect(normalizationShift(1000, []), 0);
  });
}
