import 'dart:async';

import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/ui/app_root.dart';
import 'package:easypodcast/ui/podcast_home.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_services.dart';
import 'fixtures/fake_playback_engine.dart';

Future<AppServices> _demoServices(WidgetTester tester) async {
  final services = await createDemoServices(
    engine: FakePlaybackEngine(tester.binding.clock.now),
  );
  addTearDown(() {
    services.player.dispose();
    services.downloads.dispose();
    services.library.dispose();
    services.settings.dispose();
  });
  return services;
}

void main() {
  for (final (locale, language, message, backLabel) in const [
    (Locale('cs', 'CZ'), 'cs', 'Rozposlouchané', 'Zpět'),
    (Locale('en', 'GB'), 'en', 'In progress', 'Back'),
    (Locale('de', 'DE'), 'cs', 'Rozposlouchané', 'Zpět'),
  ]) {
    testWidgets('uses $language for the system locale $locale', (tester) async {
      final services = await _demoServices(tester);
      tester.platformDispatcher.localesTestValue = [locale];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      await tester.pumpWidget(EasyPodcastApp(services: services));
      await tester.pumpAndSettle();

      expect(find.text(message), findsOneWidget);
      final context = tester.element(find.byType(PodcastHome));
      expect(Localizations.localeOf(context).languageCode, language);
      expect(MaterialLocalizations.of(context).backButtonTooltip, backLabel);
      expect(ServicesScope.of(context), same(services));
    });
  }

  testWidgets('honors 180% text on a 250 × 500 logical px screen', (
    tester,
  ) async {
    final services = await _demoServices(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(250, 500);
    tester.platformDispatcher.localesTestValue = const [Locale('cs')];
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(EasyPodcastApp(services: services));
    await tester.pumpAndSettle();

    final message = find.text('Rozposlouchané');
    final paragraph = find.descendant(
      of: message,
      matching: find.byType(RichText),
    );
    expect(tester.widget<RichText>(paragraph).textScaler.scale(20), 36);
    expect(tester.getRect(message).right, lessThanOrEqualTo(250));
    expect(tester.getRect(message).bottom, lessThanOrEqualTo(500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses GTK typography when Linux content first appears', (
    tester,
  ) async {
    final services = await _demoServices(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('easypodcast/desktop');
    final messenger = tester.binding.defaultBinaryMessenger;
    final response = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(channel, (_) => response.future);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(EasyPodcastApp(services: services));
    expect(find.byType(PodcastHome), findsNothing);

    response.complete({'family': 'Liberation Sans', 'pointSize': 18});
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(PodcastHome));
    expect(
      Theme.of(context).textTheme.bodyMedium?.fontFamily,
      'Liberation Sans',
    );
    expect(MediaQuery.textScalerOf(context).scale(14), closeTo(24, 1e-9));

    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: OutlinedButton(onPressed: () {}, child: const Text('Demo')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buttonLabel = tester.element(find.text('Demo'));
    expect(
      DefaultTextStyle.of(buttonLabel).style.fontFamily,
      'Liberation Sans',
    );
  });

  testWidgets('demo fixtures support simulated playback and queue changes', (
    tester,
  ) async {
    final services = await _demoServices(tester);
    final library = services.library;
    expect(library.podcasts, hasLength(8));
    for (final podcast in library.podcasts) {
      expect(library.episodesOf(podcast.id).length, inInclusiveRange(20, 40));
      expect(podcast.playedCount, greaterThan(0));
    }
    expect(services.downloads.downloadedEpisodeIds, hasLength(2));
    expect(library.queue, hasLength(3));
    expect(library.inProgress, hasLength(3));
    expect(
      (await services.api.fetchState())!.value.episodes.where(
        (e) => e.isDismissed,
      ),
      hasLength(1),
    );

    final id = library.inProgress.first.id;
    final initial = Duration(milliseconds: library.stateOf(id).positionMs);
    await services.player.play(id);
    expect(services.player.position.value, initial);
    await tester.pump(const Duration(seconds: 2));
    await services.player.pause();
    final simulated = initial + const Duration(seconds: 2);
    expect(services.player.position.value, simulated);
    expect(library.stateOf(id).positionMs, simulated.inMilliseconds);
    expect(services.player.isPlaying, isFalse);

    final queuedId = library.queue.first.id;
    await library.markPlayed(queuedId);
    expect(library.queue, hasLength(2));
    await library.enqueue(queuedId, next: true);
    expect(library.stateOf(queuedId).isNew, isTrue);
    expect(library.queue.first.id, queuedId);
  });
}
