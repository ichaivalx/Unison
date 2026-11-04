import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:unison_native/unison_native.dart';

import 'control/client.dart';
import 'control/console.dart';
import 'control/source_service.dart';
import 'settings.dart';
import 'ui/home.dart';
import 'ui/theme.dart';

/// Android 上由 Application 持有的引擎在进程启动时运行此入口，界面回收后控制面照常工作
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalSettings.init();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final console = ValueNotifier<Console?>(null);
  runApp(UnisonApp(console: console));
  console.value = await _open();
}

Future<Console> _open() async {
  var source = false;
  if (Platform.isAndroid) {
    try {
      source = await UnisonNative.sourceAvailable();
    } catch (_) {}
  }
  return source ? SourceService.start() : ConsoleClient.start();
}

class UnisonApp extends StatefulWidget {
  const UnisonApp({super.key, required this.console});

  final ValueNotifier<Console?> console;

  @override
  State<UnisonApp> createState() => _UnisonAppState();
}

class _UnisonAppState extends State<UnisonApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => widget.console.value?.wake());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: LocalSettings.theme,
      builder: (context, variant, _) {
        final theme = buildTheme(variant);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.light,
            systemNavigationBarContrastEnforced: false,
          ),
          child: MaterialApp(
            title: 'Unison',
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: theme,
            themeMode: ThemeMode.dark,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: HomePage(console: widget.console),
          ),
        );
      },
    );
  }
}
