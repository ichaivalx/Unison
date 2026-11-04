import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'control/models.dart';

enum DarkVariant {
  gray('深灰'),
  black('纯黑');

  const DarkVariant(this.label);

  final String label;
}

/// 本机的设置；各接收端的偏移、音量等保存在音源上
abstract final class LocalSettings {
  static late final SharedPreferences prefs;

  static const _themeKey = 'theme';
  static const _deviceIdKey = 'deviceId';
  static const _lastSourceKey = 'lastSource';
  static const _outputDeviceKey = 'outputDevice';

  static late final ValueNotifier<DarkVariant> theme;

  /// 本机设备标识，音源据此保存各设备的设置
  static late final String deviceId;
  static late final String deviceName;

  static DevicePlatform get platform =>
      Platform.isWindows ? DevicePlatform.windows : DevicePlatform.android;

  static Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    theme = ValueNotifier(DarkVariant.values.asNameMap()[prefs.getString(_themeKey)] ?? DarkVariant.gray)
      ..addListener(() => prefs.setString(_themeKey, theme.value.name));
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      final random = Random.secure();
      id = List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
      await prefs.setString(_deviceIdKey, id);
    }
    deviceId = id;
    deviceName = await _deviceName();
  }

  static Future<String> _deviceName() async {
    if (Platform.isAndroid) {
      try {
        final name = await const MethodChannel('unison/app').invokeMethod<String>('deviceName');
        if (name != null && name.isNotEmpty) return name;
      } catch (_) {}
      return 'Android';
    }
    return Platform.localHostname;
  }

  /// 上次连接的音源（host:port）
  static String? get lastSource => prefs.getString(_lastSourceKey);
  static set lastSource(String? value) =>
      value == null ? prefs.remove(_lastSourceKey) : prefs.setString(_lastSourceKey, value);

  /// Windows 的输出设备，null 为跟随系统默认
  static String? get outputDevice => prefs.getString(_outputDeviceKey);
  static set outputDevice(String? value) =>
      value == null ? prefs.remove(_outputDeviceKey) : prefs.setString(_outputDeviceKey, value);
}
