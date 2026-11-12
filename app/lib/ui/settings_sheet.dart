import 'dart:io';

import 'package:flutter/material.dart';
import 'package:unison_native/unison_native.dart';

import '../desktop.dart';
import '../settings.dart';
import 'theme.dart';

/// 本机设置：深色样式、Windows 输出设备与开机自启
Future<void> showSettingsSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _SettingsSheet(),
);

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  List<OutputDevice>? _outputs;
  OutputDevice? _output = LocalSettings.outputDevice;

  /// 开机自启：以启动项的实际状态为准，读取前为 null
  bool? _autostart;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _loadOutputs();
      _loadAutostart();
    }
  }

  Future<void> _loadAutostart() async {
    final on = await AppWindow.autostart().catchError((_) => false);
    if (mounted) setState(() => _autostart = on);
  }

  Future<void> _setAutostart(bool on) async {
    setState(() => _autostart = on);
    final actual = await AppWindow.setAutostart(on).catchError((_) => !on);
    if (mounted) setState(() => _autostart = actual);
  }

  Future<void> _loadOutputs() async {
    try {
      final outputs = await UnisonNative.outputDevices();
      if (mounted) setState(() => _outputs = outputs);
    } catch (_) {
      if (mounted) setState(() => _outputs = const []);
    }
  }

  Future<void> _setOutput(String? id) async {
    final device = id == null ? null : _outputs?.firstWhere((d) => d.id == id, orElse: () => _output!);
    setState(() => _output = device);
    LocalSettings.outputDevice = device;
    try {
      await UnisonNative.setOutputDevice(id);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final texts = context.texts;
    final colors = context.colors;
    final label = texts.titleSmall?.copyWith(fontWeight: FontWeight.w600);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('设置', style: texts.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),
          Text('外观', style: label),
          const SizedBox(height: 10),
          ValueListenableBuilder(
            valueListenable: LocalSettings.theme,
            builder: (context, theme, _) => SegmentedButton<DarkVariant>(
              showSelectedIcon: false,
              segments: [
                for (final variant in DarkVariant.values) ButtonSegment(value: variant, label: Text(variant.label)),
              ],
              selected: {theme},
              onSelectionChanged: (value) => LocalSettings.theme.value = value.single,
            ),
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 24),
            Text('输出设备', style: label),
            const SizedBox(height: 6),
            if (_outputs case final outputs?)
              RadioGroup<String?>(
                groupValue: _output?.id,
                onChanged: _setOutput,
                child: Column(
                  children: [
                    const RadioListTile<String?>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: null,
                      title: Text('跟随系统默认'),
                    ),
                    for (final device in outputs)
                      RadioListTile<String?>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: device.id,
                        title: Text(device.name),
                      ),
                    // 选定的设备暂时不在时仍保留，重新出现后原生自动切回
                    if (_output case final selected? when !outputs.any((d) => d.id == selected.id))
                      RadioListTile<String?>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: selected.id,
                        title: Text('${selected.name}（未连接）'),
                      ),
                  ],
                ),
              )
            else
              const LinearProgressIndicator(),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('开机自启', style: label),
              subtitle: Text('登录后在托盘中运行，不显示窗口', style: texts.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
              value: _autostart ?? false,
              onChanged: _autostart == null ? null : _setAutostart,
            ),
          ],
          const SizedBox(height: 24),
          Text('本机', style: label),
          const SizedBox(height: 6),
          Text(
            '${LocalSettings.deviceName} · ${LocalSettings.platform.label} · ${LocalSettings.deviceId}',
            style: texts.bodySmall?.copyWith(color: colors.onSurfaceVariant, fontFeatures: tabular),
          ),
        ],
      ),
    );
  }
}
