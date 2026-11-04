import 'dart:math' show max;

import 'package:unison_native/unison_native.dart';

/// 本机单调时钟（微秒），与原生侧时间戳同一时钟
int get nowUs => UnisonNative.monotonicUs;

/// NTP 式估计音源时钟与本机时钟的差值：保留最近的往返样本，取往返最短的
/// 四分之一求均值，再随新样本平滑
class ClockSync {
  static const _window = 40;
  static const _warmUp = 10;
  static const _smoothing = 0.3;

  final List<({double offset, int rtt})> _samples = [];
  double? _offset;
  int? _minRtt;

  bool get isReady => _samples.length >= 3;

  /// 窗口内最短的往返时间（微秒）
  int? get rttUs => _minRtt;

  void reset() {
    _samples.clear();
    _offset = null;
    _minRtt = null;
  }

  /// [sentAt]、[receivedAt] 为本机时刻，[remoteAt] 为音源收到请求时的时刻
  void add({required int sentAt, required int remoteAt, required int receivedAt}) {
    final rtt = receivedAt - sentAt;
    if (rtt < 0) return;
    _samples.add((offset: remoteAt - (sentAt + receivedAt) / 2, rtt: rtt));
    if (_samples.length > _window) _samples.removeAt(0);
    final sorted = [..._samples]..sort((a, b) => a.rtt.compareTo(b.rtt));
    final best = sorted.take(max(1, sorted.length ~/ 4));
    var sum = 0.0;
    for (final sample in best) {
      sum += sample.offset;
    }
    final estimate = sum / best.length;
    _minRtt = sorted.first.rtt;
    final current = _offset;
    _offset = current == null || _samples.length < _warmUp
        ? estimate
        : current + (estimate - current) * _smoothing;
  }

  /// 音源时刻换算为本机时刻；尚无样本时为 null
  int? toLocal(int remoteUs) {
    final offset = _offset;
    return offset == null ? null : remoteUs - offset.round();
  }
}
