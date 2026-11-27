import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/l10n/app_localizations.dart';
import 'package:easypodcast/ui/account_pages.dart';
import 'package:easypodcast/ui/app_root.dart';
import 'package:easypodcast/ui/cover_image.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_queue.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/playback_position.dart';
import 'package:easypodcast/ui/player_views.dart';
import 'package:easypodcast/ui/podcast_home.dart';
import 'package:easypodcast/ui/settings_pages.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_api.dart';
import 'fixtures/demo_downloads.dart';
import 'fixtures/demo_library.dart';
import 'fixtures/demo_services.dart';
import 'fixtures/demo_sync.dart';
import 'fixtures/fake_playback_engine.dart';

const palmaSize = Size(440, 879);
const palmaTextScale = 1.3;

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
  UiHarness._(this.tester, this.services, this.engine, this.desktop);

  final WidgetTester tester;
  final AppServices services;
  final FakePlaybackEngine engine;
  final bool desktop;
  final surface = GlobalKey();

  AppLocalizations get strings =>
      AppLocalizations.of(tester.element(find.byType(PodcastHome)));

  static Future<UiHarness> open(
    WidgetTester tester, {
    Size size = const Size(360, 720),
    Locale locale = const Locale('cs'),
    double textScale = 1.8,
    String? desktopFont,
    bool loggedIn = true,
    DemoLibrary? library,
    bool playerCover = false,
    AppServices Function(AppServices)? configure,
  }) async {
    final desktop = desktopFont != null;
    if (playerCover) await _cacheCover(desktop ? 52 : size.width.round());
    final engine = FakePlaybackEngine(tester.binding.clock.now);
    final demo = await createDemoServices(
      engine: engine,
      loggedIn: loggedIn,
      library:
          library ??
          (playerCover ? DemoLibrary(firstPodcastCover: _coverUrl) : null),
    );
    final services = configure?.call(demo) ?? demo;
    final app = UiHarness._(tester, services, engine, desktop);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.localesTestValue = [locale];
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
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
      tester.view.resetViewInsets();
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
    // EasyPodcastApp sets this global; later tests start without it.
    EditableText.debugDeterministicCursor = false;
  }

  Future<void> tap(Finder finder, {Finder? within}) async {
    if (finder.hitTestable().evaluate().isEmpty) {
      if (within == null) {
        await tester.ensureVisible(finder);
      } else {
        await scrollTo(finder, within);
      }
      await tester.pumpAndSettle();
    }
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapText(String text, {Finder? within}) =>
      tap(find.text(text), within: within);

  Future<void> row(String title) => tap(find.widgetWithText(EinkRow, title));

  Future<void> holdRow(String title, {bool rightClick = false}) async {
    final row = find.widgetWithText(EinkRow, title);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    if (rightClick) {
      await tester.tap(
        row,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
    } else {
      final hold = await tester.startGesture(
        tester.getCenter(row),
        kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
      );
      await tester.pump(EpisodeQueue.holdDuration);
      await hold.up();
    }
    await tester.pumpAndSettle();
  }

  Future<void> scrollToRow(
    String title,
    Finder view, {
    double delta = 150,
  }) async {
    final target = find.widgetWithText(EinkRow, title);
    await scrollTo(target, view, delta: delta);
    await tap(target);
  }

  Future<void> scrollTo(Finder finder, Finder view, {double delta = 150}) =>
      tester.scrollUntilVisible(
        finder,
        delta,
        scrollable: find
            .descendant(of: view, matching: find.byType(Scrollable))
            .first,
      );

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

  Future<void> dialog(String label) async {
    await tester.pump(doubleTapGuard);
    await tap(
      find.descendant(
        of: find.byType(EinkDialogPanel),
        matching: find.text(label),
      ),
    );
  }

  String episode(int id) => services.library.episode(id)!.title;

  Future<void> openEpisode(int id) => row(episode(id));

  Future<void> login({bool reject = false}) async {
    (services.api as DemoApiClient).loginErrorCode = reject ? 401 : null;
    for (final (key, text) in [
      if (tester
          .widget<TextField>(_loginField('login-address'))
          .controller!
          .text
          .isEmpty)
        ('login-address', 'https://podcast.example'),
      ('login-name', 'listener'),
      ('login-password', 'demo password'),
    ]) {
      await tester.enterText(_loginField(key), text);
    }
    await tapText(strings.signIn, within: find.byType(LoginPage));
  }

  Finder _loginField(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(TextField),
  );
}

const _coverUrl = 'https://podcast.example/1/cover.png';

Future<void> _cacheCover(int largest) async {
  final cache = PaintingBinding.instance.imageCache;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size.square(192);
  final paint = Paint()..color = const Color(0xffb4cbd3);
  canvas.drawRect(Offset.zero & size, paint);
  paint.color = const Color(0xffe5c596);
  canvas.drawCircle(const Offset(136, 55), 24, paint);
  paint.color = const Color(0xff506e62);
  canvas.drawPath(
    Path()
      ..moveTo(0, 100)
      ..lineTo(43, 58)
      ..lineTo(73, 88)
      ..lineTo(108, 70)
      ..lineTo(192, 108)
      ..lineTo(192, 192)
      ..lineTo(0, 192)
      ..close(),
    paint,
  );
  paint
    ..color = const Color(0xffd7cca5)
    ..strokeWidth = 3;
  for (final (y, halfWidth) in const [
    (102.0, 9.0),
    (116.0, 15.0),
    (136.0, 22.0),
    (161.0, 32.0),
    (189.0, 45.0),
  ]) {
    canvas.drawLine(
      Offset(99 - halfWidth, y),
      Offset(99 + halfWidth, y),
      paint,
    );
  }
  paint
    ..color = const Color(0xff292e39)
    ..strokeWidth = 5;
  canvas.drawLine(const Offset(94, 93), const Offset(60, 192), paint);
  canvas.drawLine(const Offset(104, 93), const Offset(138, 192), paint);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(192, 192);
  picture.dispose();
  final completer = OneFrameImageStreamCompleter(
    Future.value(ImageInfo(image: image)),
  );
  final keys = [
    for (var size = 1; size <= largest; size++)
      await ResizeImage(
        const CoverImage(_coverUrl),
        width: size,
        height: size,
        policy: ResizeImagePolicy.fit,
      ).obtainKey(ImageConfiguration.empty),
  ];
  for (final key in keys) {
    cache.putIfAbsent(key, () => completer);
  }
  addTearDown(() {
    for (final key in keys) {
      cache.evict(key);
    }
  });
}

typedef VisitScreen = Future<void> Function(String name);

Future<void> tourPhone(UiHarness app, VisitScreen visit) async {
  app.services.settings.showSpeedAndSleep = true;
  final l = app.strings;
  final downloads = app.services.downloads as DemoDownloadService;
  const running = DownloadInfo(DownloadStatus.running, progress: 0.43);
  downloads.setDownloadInfo(704, running);
  downloads.setDownloadInfo(203, running);
  await app.tester.pumpAndSettle();
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
  final track = app.tester.getRect(find.byKey(PlaybackTimeline.trackKey));
  final seek = await app.tester.startGesture(track.center);
  await seek.moveTo(track.center + Offset(track.width / 5, 0));
  await visit('27-player-seeking');
  await seek.cancel();
  await app.tester.pumpAndSettle();
  await app.tapText(l.speed);
  await visit('06-speed');
  await app.dialog(l.close);
  await app.tapText(l.sleep);
  await app.dialog(l.minutes(30));
  await app.tapText(l.sleep);
  await visit('18-sleep');
  await app.dialog(l.sleepOff);
  await app.back();

  await app.services.library.enqueue(101, next: true);
  await app.section(LibrarySection.queue);
  await visit('07-queue');
  final downloading = l.numberedTitle(2, app.episode(203));
  await app.holdRow(downloading);
  await visit('08-episode-actions');
  await app.dialog(l.close);
  await app.row(downloading);
  await visit('26-downloading-episode');
  await app.back();
  await downloads.delete(203);
  await downloads.delete(704);

  await app.section(LibrarySection.newEpisodes);
  await visit('09-new-episodes');
  await app.openEpisode(201);
  await visit('12-new-episode');
  await app.tapText(l.dismissOlder);
  await visit('24-dismiss-older');
  await app.dialog(l.cancel);
  await app.back();
  await app.back();

  await app.section(LibrarySection.search);
  await visit('36-search');
  await app.tester.enterText(find.byType(TextField), 'noční');
  await app.tester.pump(const Duration(milliseconds: 400));
  await app.scrollTo(find.text(l.foundInDescription), find.byType(EpisodeList));
  await visit('37-search-descriptions');
  await app.back();

  await app.section(LibrarySection.podcasts);
  await visit('10-podcasts');
  final library = app.services.library as DemoLibrary;
  await app.holdRow(library.podcasts.first.title);
  await visit('32-podcast-menu');
  await app.dialog(l.unsubscribe);
  await visit('33-podcast-menu-unsubscribe');
  await app.dialog(l.cancel);
  library.beforeShowInNewEpisodes = (_, _) async => throw OfflineException();
  await app.dialog(l.showInNewEpisodes);
  expect(find.text(l.actionFailed), findsOneWidget);
  await visit('34-podcast-menu-error');
  library.beforeShowInNewEpisodes = null;
  await app.dialog(l.close);
  await app.scrollToRow(l.addPodcast, find.byType(PodcastList), delta: -150);
  await visit('19-add-podcast');
  await app.tester.enterText(find.byType(TextField).first, 'noční vlak');
  app.tester.view.viewInsets = const FakeViewPadding(bottom: 320);
  await app.tester.pumpAndSettle();
  expect(app.tester.testTextInput.isVisible, isTrue);
  await visit('35-add-podcast-keyboard');
  app.tester.view.resetViewInsets();
  await app.tap(find.widgetWithText(EinkButton, l.search));
  await visit('31-directory-results');
  await app.back();
  await app.scrollToRow(
    app.services.library.podcast(1)!.title,
    find.byType(PodcastList),
  );
  await visit('11-podcast');
  await app.row(l.searchThisPodcast);
  await app.tester.enterText(find.byType(TextField), 'nocni nadrazi');
  await visit('30-podcast-search');
  await app.tap(find.byTooltip(l.clearSearch));
  await app.tap(find.byTooltip(l.aboutPodcast));
  await visit('20-about-podcast');
  await app.tapText(l.unsubscribe);
  expect(find.text(l.unsubscribeTitle), findsOneWidget);
  await app.dialog(l.unsubscribe);
  final unsubscribed = find.text(l.notSubscribed);
  await app.scrollTo(unsubscribed, find.byType(AboutPodcastPage));
  await app.tester.pumpAndSettle();
  expect(unsubscribed.hitTestable(), findsOneWidget);
  await visit('25-unsubscribe');
  await app.back();
  await app.back();
  await app.back();

  (app.services.sync as DemoSyncService).setOffline();
  downloads.queueDownload(602, waitingForWifi: true);
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
  await app.tapText(l.logout, within: find.byType(ServerPage));
  await visit('16-login');
  await app.login(reject: true);
  await visit('17-login-error');
}

Future<void> tourDesktop(
  UiHarness app,
  VisitScreen visit, {
  bool allScreens = true,
}) async {
  app.services.settings.showSpeedAndSleep = true;
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
  final queueTitle = l.numberedTitle(2, app.episode(401));
  await app.scrollTo(
    find.widgetWithText(EinkRow, queueTitle),
    find.byType(EpisodeQueue),
  );
  await app.holdRow(queueTitle, rightClick: true);
  await visit('pc-episode-actions');
  await app.dialog(l.close);
  await app.section(LibrarySection.newEpisodes);
  await app.openEpisode(201);
  await visit('pc-new');
  await app.tapText(l.dismissOlder);
  await visit('pc-dismiss-older');
  await app.dialog(l.cancel);
  await app.section(LibrarySection.search);
  await visit('pc-search');
  await app.section(LibrarySection.podcasts);
  await visit('pc-podcasts');
  await app.row(l.addPodcast);
  await visit('pc-add');
  await app.tester.enterText(find.byType(TextField).first, 'noční vlak');
  await app.tap(find.widgetWithText(EinkButton, l.search));
  await visit('pc-directory-results');
  await app.back();
  await app.scrollToRow(
    app.services.library.podcast(1)!.title,
    find.byType(PodcastList),
  );
  await visit('pc-podcast');
  await app.tap(find.byTooltip(l.aboutPodcast));
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
  await app.tapText(l.logout, within: find.byType(ServerPage));
  await visit('pc-login');
  await app.login(reject: true);
  await visit('pc-login-error');
}
