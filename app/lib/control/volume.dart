import 'package:unison_native/unison_native.dart';

/// 设定本机音量，并区分音量回报中的用户调整：记住当前已知的实际音量（设定后回读，
/// Android 为按音量档位取整后的值），与之相同的回报一律忽略（含同一次设定的重复
/// 回报），不同的才是用户调整
class VolumeSetter {
  VolumeSetter({required this.onUser});

  /// 用户调整了音量（含设定期间发生、设定完成后才判定的）
  final void Function(double volume) onUser;

  /// 当前已知的实际音量
  double? _known;
  int _pending = 0;

  /// 设定期间收到的最后一次回报，设定完成后判定
  double? _seen;

  static bool _same(double a, double? b) => b != null && (a - b).abs() < 1e-6;

  /// 设定音量，返回实际生效的值
  Future<double> set(double volume) async {
    _pending++;
    try {
      await UnisonNative.setVolume(volume);
      return _known = await UnisonNative.volume();
    } finally {
      _pending--;
      if (_pending == 0) {
        final seen = _seen;
        _seen = null;
        if (seen != null && !_same(seen, _known)) {
          _known = seen;
          onUser(seen);
        }
      }
    }
  }

  /// 音量回报是否为用户调整；设定期间的回报留待设定完成后判定，此时返回 false。
  /// 尚无已知音量时（如订阅时的首次回报）只记录
  bool isUser(double volume) {
    if (_pending > 0) {
      _seen = volume;
      return false;
    }
    if (_known == null || _same(volume, _known)) {
      _known = volume;
      return false;
    }
    _known = volume;
    return true;
  }
}
