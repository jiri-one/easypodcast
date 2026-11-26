import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/services.dart';
import '../l10n/app_localizations.dart';
import '../platform/desktop_font.dart';
import 'podcast_home.dart';
import 'theme.dart';

class EasyPodcastApp extends StatelessWidget {
  const EasyPodcastApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => ServicesScope(
    services: services,
    child: !kIsWeb && defaultTargetPlatform == TargetPlatform.linux
        ? const _LinuxApp()
        : const _App(),
  );
}

class ServicesScope extends InheritedWidget {
  const ServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ServicesScope>()!.services;

  @override
  bool updateShouldNotify(ServicesScope oldWidget) =>
      !identical(services, oldWidget.services);
}

class _LinuxApp extends StatefulWidget {
  const _LinuxApp();

  @override
  State<_LinuxApp> createState() => _LinuxAppState();
}

class _LinuxAppState extends State<_LinuxApp> {
  late final Future<DesktopFont?> _font;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    // GTK shows the window when Flutter sends its first frame.
    binding.deferFirstFrame();
    _font = desktopFont().whenComplete(binding.allowFirstFrame);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<DesktopFont?>(
    future: _font,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const ColoredBox(color: Colors.white);
      }
      return _App(font: snapshot.data);
    },
  );
}

class _App extends StatelessWidget {
  const _App({this.font});

  final DesktopFont? font;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: einkTheme(fontFamily: font?.family),
    themeAnimationDuration: Duration.zero,
    scrollBehavior: const _EinkScrollBehavior(),
    builder: (context, child) {
      final desktop = font;
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: desktop == null
              ? null
              : TextScaler.linear(desktop.textScale),
        ),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: einkSystemOverlayStyle,
          child: ColoredBox(color: Colors.white, child: child!),
        ),
      );
    },
    home: const PodcastHome(),
  );
}

class _EinkScrollBehavior extends MaterialScrollBehavior {
  const _EinkScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
