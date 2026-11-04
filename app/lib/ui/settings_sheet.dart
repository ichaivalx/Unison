import 'dart:io';

import 'package:flutter/material.dart';
import 'package:unison_native/unison_native.dart';

import '../settings.dart';
import 'theme.dart';

/// 本机设置：深色样式、Windows 输出设备
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
  List<String>? _outputs;
  String? _output = LocalSettings.outputDevice;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) _loadOutputs();
  }

  Future<void> _loadOutputs() async {
    try {
      final outputs = await UnisonNative.outputDevices();
      if (mounted) setState(() => _outputs = outputs);
    } catch (_) {
      if (mounted) setState(() => _outputs = const []);
    }
  }

  Future<void> _setOutput(String? name) async {
    setState(() => _output = name);
    LocalSettings.outputDevice = name;
    try {
      await UnisonNative.setOutputDevice(name);
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
                groupValue: _output,
                onChanged: _setOutput,
                child: Column(
                  children: [
                    for (final name in <String?>[null, ...outputs])
                      RadioListTile<String?>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: name,
                        title: Text(name ?? '跟随系统默认'),
                      ),
                  ],
                ),
              )
            else
              const LinearProgressIndicator(),
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
