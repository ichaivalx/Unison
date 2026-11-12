import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/control/console.dart';
import 'package:unison/control/models.dart';
import 'package:unison/settings.dart';
import 'package:unison/ui/home.dart';
import 'package:unison/ui/theme.dart';
import 'package:unison_native/unison_native.dart';

/// 首页在手机竖屏、平板横屏与桌面窗口下的截图，写入 build/screenshots 供检查布局；
/// 溢出等渲染错误使测试失败。中文字体由 CI 下载到 build/test_fonts
void main() {
  setUpAll(_loadFonts);

  testWidgets('手机竖屏，接收端', (tester) async {
    await _render(tester, const Size(400, 860), self: 'phone', top: 28);
    await _shot(tester, 'phone');
    // 从右侧边距处拖动页面，避开可拖动的控件
    await tester.dragFrom(const Offset(394, 400), const Offset(0, -640));
    await tester.pumpAndSettle();
    await _shot(tester, 'phone-devices');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('平板横屏，音源', (tester) async {
    await _render(tester, const Size(1280, 800), self: 'pad', top: 24);
    await _shot(tester, 'tablet');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('桌面窗口，接收端', (tester) async {
    await _render(tester, const Size(1100, 720), self: 'pc', desktop: true);
    await _shot(tester, 'desktop');
    await tester.pumpWidget(const SizedBox());
  });
}

const _frame = ValueKey('frame');

Future<void> _render(WidgetTester tester, Size size, {required String self, double top = 0, bool desktop = false}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = size * 2
    ..padding = FakeViewPadding(top: top * 2);
  addTearDown(tester.view.reset);
  final console = _Console(self, _state());
  await tester.pumpWidget(
    RepaintBoundary(
      key: _frame,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(DarkVariant.gray),
        home: HomePage(console: ValueNotifier(console), desktop: desktop),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _shot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_frame));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screenshots/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Future<void> _loadFonts() async {
  Future<void> load(String family, File file) async {
    if (!file.existsSync()) return;
    final bytes = ByteData.sublistView(file.readAsBytesSync());
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }

  await load('Roboto', File('build/test_fonts/NotoSansSC.ttf'));
  // Material 图标随 Flutter SDK 提供：flutter_tester 位于 bin/cache/artifacts/engine/<平台>/
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
  await load('MaterialIcons', File('${artifacts.path}/material_fonts/MaterialIcons-Regular.otf'));
}

class _Console implements Console {
  _Console(this.selfId, ConsoleState state) : state = ValueNotifier(state);

  @override
  final ValueNotifier<ConsoleState?> state;

  @override
  final connected = ValueNotifier(true);

  @override
  final String selfId;

  @override
  bool get isSource => selfId == 'pad';

  @override
  void command(String command, [Map<String, Object?> args = const {}]) {}

  @override
  int localTimeOf(int sourceUs) => sourceUs;

  @override
  void wake({required bool returned}) {}
}

ReceiverStats _stats({required bool clockReady, required int errorUs}) => ReceiverStats(
  running: true,
  sourceHost: '192.168.1.20',
  clockReady: clockReady,
  syncErrorUs: errorUs,
  bufferUs: 42000,
  rttUs: 3100,
  lostPackets: 0,
  latePackets: 2,
  xruns: 0,
  speedPpm: -12.4,
  realTimestamp: true,
  outputDevice: '扬声器',
);

ConsoleState _state() => ConsoleState(
  sourceId: 'pad',
  source: const SourceView(
    running: true,
    latencyUs: 50000,
    localDelayUs: 12000,
    error: null,
    sessions: [
      SessionView(app: 'PiliPlus', channel: 'PRIMARY|FAST', delayUs: 102000, calibrated: true),
      SessionView(app: 'YouTube', channel: 'DEEP_BUFFER', delayUs: 12000, calibrated: true),
      SessionView(app: '网易云音乐', channel: 'COMPRESS_OFFLOAD', delayUs: 12000, calibrated: false),
    ],
    uncaptured: [UncapturedView(app: '酷狗音乐', packageName: 'com.kugou.android', sessionId: 4217)],
    channels: [
      ChannelView(channel: 'DEEP_BUFFER', latencyUs: 148000, compensationUs: 0, base: true),
      ChannelView(channel: 'PRIMARY|FAST', latencyUs: 58000, compensationUs: 90000, base: false),
    ],
  ),
  media: const MediaView(
    packageName: 'com.google.android.youtube',
    appName: 'YouTube',
    title: '深夜电台 · 城市的另一面（现场版）',
    artist: '某某乐队',
    durationUs: 245000000,
    positionUs: 83000000,
    positionAtUs: 0,
    speed: 1,
    playing: false,
    canSeek: true,
  ),
  devices: [
    const DeviceView(
      id: 'pad',
      name: 'OnePlus Pad 3',
      platform: DevicePlatform.android,
      isSource: true,
      online: true,
      receive: false,
      receiving: false,
      offsetUs: 0,
      volume: VolumeSetting.initial,
      actualVolume: 0.6,
      stats: null,
    ),
    DeviceView(
      id: 'pc',
      name: 'OLED-PC',
      platform: DevicePlatform.windows,
      isSource: false,
      online: true,
      receive: true,
      receiving: true,
      offsetUs: 12500,
      volume: const VolumeSetting(mode: VolumeMode.follow, offset: -0.05, level: 0.5),
      actualVolume: 0.55,
      stats: _stats(clockReady: true, errorUs: 120),
      blackout: false,
    ),
    DeviceView(
      id: 'phone',
      name: 'Pixel 8',
      platform: DevicePlatform.android,
      isSource: false,
      online: true,
      receive: true,
      receiving: true,
      offsetUs: -3000,
      volume: const VolumeSetting(mode: VolumeMode.independent, offset: 0, level: 0.4),
      actualVolume: 0.4,
      stats: _stats(clockReady: false, errorUs: 0),
    ),
    const DeviceView(
      id: 'speaker',
      name: '客厅 Xiaomi 平板 5 Pro',
      platform: DevicePlatform.android,
      isSource: false,
      online: false,
      receive: false,
      receiving: false,
      offsetUs: 0,
      volume: VolumeSetting.initial,
      actualVolume: null,
      stats: null,
    ),
  ],
  calibration: const CalibrationView(),
  band: const BandView(weight: 0, available: true, notes: []),
  boost: 0.6,
  sentAtUs: 0,
);
