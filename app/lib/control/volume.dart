import 'package:unison_native/unison_native.dart';

/// 设定本机音量，并区分其引起的音量回报与用户调整：设定后回读实际值（Android 按
/// 音量档位取整后的值），只有与之相同的一次回报算自身所致，其余变化都是用户调整
class VolumeSetter {
  VolumeSetter({required this.onUser});

  /// 用户调整了音量（含设定期间发生、设定完成后才判定的）
  final void Function(double volume) onUser;

  /// 本次设定后的实际值，尚未收到对应回报
  double? _expected;
  int _pending = 0;

  /// 设定期间收到的回报，设定完成后判定
  double? _seen;

  static bool _same(double a, double? b) => b != null && (a - b).abs() < 1e-6;

  /// 设定音量，返回实际生效的值
  Future<double> set(double volume) async {
    _pending++;
    try {
      await UnisonNative.setVolume(volume);
      return _expected = await UnisonNative.volume();
    } finally {
      _pending--;
      if (_pending == 0) {
        final seen = _seen;
        _seen = null;
        if (seen != null) {
          if (_same(seen, _expected)) {
            _expected = null;
          } else {
            _expected = null;
            onUser(seen);
          }
        }
      }
    }
  }

  /// 音量回报是否为用户调整；设定期间的回报留待设定完成后判定，此时返回 false
  bool isUser(double volume) {
    if (_pending > 0) {
      _seen = volume;
      return false;
    }
    final self = _same(volume, _expected);
    _expected = null;
    return !self;
  }
}
