import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:unison_native/unison_native.dart';

// 临时宿主入口：实际加载插件，不 mock 平台通道，不显示窗口或改系统默认设备。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final data = <String, Object?>{};
  final stats = <ReceiverStats>[];
  final volumes = <double>[];
  StreamSubscription<ReceiverStats>? status;
  StreamSubscription<double>? volume;
  var code = 0;
  try {
    final before = UnisonNative.monotonicUs;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (UnisonNative.monotonicUs <= before) throw StateError('Clock did not advance');
    final id = await UnisonNative.receiverId();
    final devices = await UnisonNative.outputDevices();
    data['receiverId'] = id; data['devices'] = devices;
    final selected = devices.where((s) => s.contains('Steam Streaming Speakers')).firstOrNull;
    await UnisonNative.setOutputDevice(selected);
    status = UnisonNative.receiverStats.listen(stats.add);
    volume = UnisonNative.volumeChanges.listen(volumes.add);
    await UnisonNative.setVolume(0);
    await UnisonNative.setReceiverOffsetUs(1250);
    await UnisonNative.startReceiver(sourceHost: args.isEmpty ? '127.0.0.1' : args.first);
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!stats.any((s) => s.running)) throw StateError('Missing running statistics');
    await UnisonNative.stopReceiver();
    await UnisonNative.startReceiver(sourceHost: args.isEmpty ? '127.0.0.1' : args.first);
    if (await UnisonNative.receiverId() != id) throw StateError('receiverId changed after restart');
    await UnisonNative.setVolume(0.25);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if ((await UnisonNative.volume() - 0.25).abs() > 0.01 || !volumes.any((v) => (v - 0.25).abs() < 0.01)) {
      throw StateError('Volume getter/events mismatch');
    }
    await UnisonNative.setVolume(0);
    await UnisonNative.stopReceiver();
    await UnisonNative.setOutputDevice(null);
    var unsupported = false;
    try { await UnisonNative.sourceAvailable(); } on UnsupportedError { unsupported = true; }
    if (!unsupported) throw StateError('Windows source capability must be unsupported');
    data['outputDevice'] = stats.last.outputDevice;
    data['clockReady'] = stats.any((s) => s.clockReady);
    data['statsEvents'] = stats.length; data['volumeEvents'] = volumes; data['ok'] = true;
  } catch (error, trace) { data['ok'] = false; data['error'] = '$error'; data['trace'] = '$trace'; code = 1; }
  finally {
    await UnisonNative.stopReceiver();
    await status?.cancel(); await volume?.cancel();
    File('${Platform.resolvedExecutable}.result.json').writeAsStringSync(jsonEncode(data));
  }
  exit(code);
}
