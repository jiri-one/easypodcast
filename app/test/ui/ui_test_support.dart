import 'dart:io';

import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/l10n/app_localizations.dart';
import 'package:easypodcast/ui/app_root.dart';
import 'package:easypodcast/ui/demo/demo_api.dart';
import 'package:easypodcast/ui/demo/demo_downloads.dart';
import 'package:easypodcast/ui/demo/demo_services.dart';
import 'package:easypodcast/ui/demo/demo_sync.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/player_views.dart';
import 'package:easypodcast/ui/podcast_home.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<String> loadTestFonts() async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  final fonts = {
    for (final file in Directory('/usr/share/fonts').listSync(recursive: true))
      if (file is File) file.uri.pathSegments.last: file,
  };
  for (final (family, regular, bold) in const [
    (
      'Liberation Sans',
      'LiberationSans-Regular.ttf',
      'LiberationSans-Bold.ttf',
    ),
    ('Noto Sans', 'NotoSans-Regular.ttf', 'NotoSans-Bold.ttf'),
    ('DejaVu Sans', 'DejaVuSans.ttf', 'DejaVuSans-Bold.ttf'),
  ]) {
    final font = fonts[regular];
    if (font == null) continue;
    final regularData = ByteData.sublistView(await font.readAsBytes());
    final boldFont = fonts[bold];
    final boldData = boldFont == null
        ? null
        : ByteData.sublistView(await boldFont.readAsBytes());
    for (final alias in [family, 'Roboto']) {
      final loader = FontLoader(alias)..addFont(Future.value(regularData));
      if (boldData != null) loader.addFont(Future.value(boldData));
      await loader.load();
    }
    return family;
  }
  throw StateError('Install Liberation Sans, Noto Sans, or DejaVu Sans.');
}

class UiHarness {
  UiHarness._(this.tester, this.services, this.desktop);

  final WidgetTester tester;
  final AppServices services;
  final bool desktop;
  final surface = GlobalKey();

  AppLocalizations get strings =>
      AppLocalizations.of(tester.element(find.byType(PodcastHome)));

  static Future<UiHarness> open(
    WidgetTester tester, {
    required Size size,
    required Locale locale,
    String? desktopFont,
    bool loggedIn = true,
  }) async {
    final desktop = desktopFont != null;
    final services = await createDemoServices(loggedIn: loggedIn);
    final app = UiHarness._(tester, services, desktop);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.localesTestValue = [locale];
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    debugDefaultTargetPlatformOverride = desktop
        ? TargetPlatform.linux
        : TargetPlatform.android;
    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('easypodcast/desktop');
    if (desktop) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'family': desktopFont, 'pointSize': 18},
      );
    }
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      tester.platformDispatcher.clearLocalesTestValue();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      debugDefaultTargetPlatformOverride = null;
      services.player.dispose();
      services.downloads.dispose();
      services.library.dispose();
      services.settings.dispose();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: app.surface,
        child: EasyPodcastApp(services: services),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  Future<void> finish() async {
    await services.player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> tap(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapText(String text) => tap(find.text(text));

  Future<void> row(String title) => tap(find.widgetWithText(EinkRow, title));

  Future<void> scrollToRow(
    String title,
    Finder view, {
    double delta = 150,
  }) async {
    final target = find.widgetWithText(EinkRow, title);
    await tester.scrollUntilVisible(
      target,
      delta,
      scrollable: find.descendant(of: view, matching: find.byType(Scrollable)),
    );
    await tap(target);
  }

  Future<void> menu() => tap(find.byType(EinkHeader).first);

  Future<void> section(LibrarySection section) async {
    if (!desktop) await menu();
    await row(section.label(tester.element(find.byType(PodcastHome))));
  }

  Future<void> back() async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> mini(String label) => tap(
    find.descendant(of: find.byType(MiniPlayer), matching: find.text(label)),
  );

  Future<void> dialog(String label) => tap(
    find.descendant(
      of: find.byType(EinkDialogPanel),
      matching: find.text(label),
    ),
  );

  String episode(int id) => services.library.episode(id)!.title;

  Future<void> openEpisode(int id) => row(episode(id));

  Future<void> login({bool reject = false}) async {
    (services.api as DemoApiClient).loginErrorCode = reject ? 401 : null;
    for (final (key, text) in [
      ('login-name', 'listener'),
      ('login-password', 'demo password'),
    ]) {
      await tester.enterText(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(TextField),
        ),
        text,
      );
    }
    await tapText(strings.signIn);
  }
}

typedef VisitScreen = Future<void> Function(String name);

Future<void> tourPhone(UiHarness app, VisitScreen visit) async {
  final l = app.strings;
  await visit('01-in-progress');
  await app.menu();
  await visit('02-list-switcher');
  await app.back();

  await app.openEpisode(204);
  await visit('03-episode');
  await app.tapText(l.dismiss);
  await visit('04-dismiss-confirm');
  await app.dialog(l.cancel);
  await app.back();

  await app.mini(l.play);
  await app.mini(app.episode(101));
  await visit('05-player');
  await app.tapText(l.speed);
  await visit('06-speed');
  await app.dialog(l.close);
  await app.tapText(l.sleep);
  await app.dialog(l.minutes(30));
  await app.tapText(l.sleep);
  await visit('18-sleep');
  await app.dialog(l.sleepOff);
  await app.back();

  await app.section(LibrarySection.queue);
  await visit('07-queue');
  await app.row(l.queueEdit);
  await app.row(l.numberedTitle(2, app.episode(401)));
  await visit('08-queue-order');
  await app.back();
  await app.back();

  await app.section(LibrarySection.newEpisodes);
  await visit('09-new-episodes');
  await app.openEpisode(201);
  await visit('12-new-episode');
  await app.tapText(l.dismissOlder);
  await visit('24-dismiss-older');
  await app.dialog(l.cancel);
  await app.back();
  await app.back();

  await app.section(LibrarySection.podcasts);
  await visit('10-podcasts');
  await app.row(l.addPodcast);
  await visit('19-add-podcast');
  await app.back();
  await app.scrollToRow(
    app.services.library.podcast(1)!.title,
    find.byType(PodcastList),
  );
  await visit('11-podcast');
  await app.row(l.aboutPodcast);
  await visit('20-about-podcast');
  await app.tapText(l.unsubscribe);
  expect(find.text(l.notSubscribed), findsOneWidget);
  await visit('25-unsubscribe');
  await app.back();
  await app.back();
  await app.back();

  (app.services.sync as DemoSyncService).setOffline();
  (app.services.downloads as DemoDownloadService).queueDownload(602);
  await app.section(LibrarySection.downloads);
  await visit('13-downloads-offline');
  await app.back();
  await app.services.sync.syncNow();

  await app.section(LibrarySection.settings);
  await visit('14-settings');
  await app.scrollToRow(
    l.feedStatus,
    find.byKey(const PageStorageKey('settings-list')),
  );
  await visit('22-feed-status');
  await app.back();
  await app.scrollToRow(
    l.opml,
    find.byKey(const PageStorageKey('settings-list')),
  );
  await visit('23-opml');
  await app.back();
  await app.scrollToRow(
    l.server,
    find.byKey(const PageStorageKey('settings-list')),
    delta: -150,
  );
  await visit('21-server');
  await app.tapText(l.logout);
  await visit('16-login');
  await app.login(reject: true);
  await visit('17-login-error');
}

Future<void> tourDesktop(
  UiHarness app,
  VisitScreen visit, {
  bool allScreens = true,
}) async {
  final l = app.strings;
  await app.tap(
    find.descendant(
      of: find.byType(DesktopPlayer),
      matching: find.text(l.play),
    ),
  );
  await app.openEpisode(204);
  await visit('15-pc');
  if (!allScreens) return;

  await app.tapText(l.dismiss);
  await visit('pc-dismiss');
  await app.dialog(l.cancel);
  await app.tapText(
    l.desktopSpeed(l.speedValue(l.localeName == 'cs' ? '1,0' : '1.0')),
  );
  await visit('pc-speed');
  await app.dialog(l.close);
  await app.section(LibrarySection.queue);
  await visit('pc-queue');
  await app.row(l.queueEdit);
  await app.tap(
    find.descendant(
      of: find.byType(QueueEditor),
      matching: find.widgetWithText(
        EinkRow,
        l.numberedTitle(2, app.episode(401)),
      ),
    ),
  );
  await visit('pc-reorder');
  await app.section(LibrarySection.newEpisodes);
  await app.openEpisode(201);
  await visit('pc-new');
  await app.tapText(l.dismissOlder);
  await visit('pc-dismiss-older');
  await app.dialog(l.cancel);
  await app.section(LibrarySection.podcasts);
  await visit('pc-podcasts');
  await app.row(l.addPodcast);
  await visit('pc-add');
  await app.back();
  await app.scrollToRow(
    app.services.library.podcast(1)!.title,
    find.byType(PodcastList),
  );
  await visit('pc-podcast');
  await app.row(l.aboutPodcast);
  await visit('pc-about');
  await app.section(LibrarySection.settings);
  await visit('pc-settings');
  final settings = find.byKey(const PageStorageKey('settings-list'));
  await app.scrollToRow(l.feedStatus, settings);
  await visit('pc-feeds');
  await app.scrollToRow(l.opml, settings);
  await visit('pc-opml');
  await app.scrollToRow(l.server, settings, delta: -150);
  await visit('pc-server');
  await app.tapText(l.logout);
  await visit('pc-login');
  await app.login(reject: true);
  await visit('pc-login-error');
}
