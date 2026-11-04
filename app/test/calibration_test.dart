import 'package:flutter_test/flutter_test.dart';
import 'package:unison/control/calibration.dart';
import 'package:unison_native/unison_native.dart';

List<BandMeasurement> _m(int? mid, {int? bass}) => [
  BandMeasurement(band: CalibrationBand.midHigh, arrivalUs: mid, spreadUs: 0, rounds: 3),
  BandMeasurement(band: CalibrationBand.bass, arrivalUs: bass, spreadUs: 0, rounds: 3),
];

void main() {
  test('接收端较早时增加偏移，较晚时推迟本机', () {
    final outcome = solveCalibration(
      localDelayUs: 0,
      effective: {'a': 1000, 'b': 0},
      bases: {'a': 1000, 'b': 0, 'c': 500},
      local: _m(30000, bass: 33000),
      receivers: {'a': _m(28000, bass: 32000), 'b': _m(32000)},
    );
    // a：1000 + 30000 − 28000 = 3000；b：0 + 30000 − 32000 = −2000，本机推迟 2000
    expect(outcome.localDelayUs, 2000);
    expect(outcome.baseOffsets, {'a': 5000, 'b': 0, 'c': 2500});
    expect(outcome.gaps['a'], {CalibrationBand.bass: 4000});
    expect(outcome.localGaps, {CalibrationBand.bass: 3000});
    expect(bandShift(1, outcome.gaps['a']!, outcome.localGaps), -1000);
    expect(bandShift(1, outcome.gaps['b']!, outcome.localGaps), 0);
  });

  test('各偏移为正时先减少本机延迟', () {
    final outcome = solveCalibration(
      localDelayUs: 3000,
      effective: {'a': 0},
      bases: {'a': 0},
      local: _m(30000),
      receivers: {'a': _m(25000)},
    );
    expect(outcome.localDelayUs, 0);
    expect(outcome.baseOffsets, {'a': 2000});
  });
}
