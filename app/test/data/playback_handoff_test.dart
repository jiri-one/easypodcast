import 'dart:async';

import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/settings.dart';
import 'package:easypodcast/player/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final action in ['pause', 'seek', 'completion']) {
    test(
      '$action sends through an offline retry wait before another device resumes',
      () async {
        final clock = TestClock();
        final server = FakeServer(clock)..addPodcast(1, 'Garden Talk');
        final id = server.addEpisodes(1, 1).single;
        const retry = Duration(seconds: 30);
        final phone = await Device.open(
          server,
          initialBackoff: retry,
          maxBackoff: retry,
        );
        addTearDown(phone.close);
        await phone.loginAndStart('phone');
        final pc = await Device.open(server);
        addTearDown(pc.close);
        await pc.loginAndStart('pc');
        SharedPreferences.setMockInitialValues({'autoplayQueue': false});
        final settings = await Settings.load();
        addTearDown(settings.dispose);
        final engine = _SilentEngine();
        final player = EpisodePlayer(
          library: phone.library,
          sync: phone.sync,
          downloads: _NoDownloads(),
          settings: settings,
          engine: engine,
          clock: clock.call,
        );
        addTearDown(player.dispose);

        await player.play(id);
        phone.api.online = false;
        await phone.library.recordPosition(id, const Duration(minutes: 20));
        await phone.sync.whenIdle();
        expect(phone.sync.currentBackoff, retry);
        phone.api.online = true;
        clock.advance(const Duration(minutes: 14));
        const position = Duration(minutes: 34);
        final sent = Completer<void>();
        phone.api.transformPushResult = (result) {
          if (!sent.isCompleted) sent.complete();
          return result;
        };
        switch (action) {
          case 'pause':
            engine.position = position;
            await player.pause();
          case 'seek':
            await player.seekTo(position);
          case 'completion':
            engine.complete();
        }
        await sent.future.timeout(const Duration(seconds: 2));
        await phone.sync.whenIdle();
        await pc.sync.freshStateBeforePlay(id);
        final received = pc.library.stateOf(id);
        expect(received.updatedAt, clock.now);
        expect(received.isPlayed, action == 'completion');
        expect(
          received.positionMs,
          action == 'completion' ? 0 : position.inMilliseconds,
        );
      },
    );
  }
}

class _NoDownloads extends Fake implements DownloadService {
  @override
  String? localFileOf(int episodeId) => null;
}

class _SilentEngine implements PlaybackEngine {
  final _changes = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Stream<PlaybackInterruption> get interruptions => const Stream.empty();
  @override
  Duration position = Duration.zero;
  @override
  Duration get bufferedPosition => position;
  @override
  Duration get duration => const Duration(hours: 1);
  @override
  ProcessingState processingState = ProcessingState.ready;
  @override
  bool playing = false;

  void complete() {
    position = duration;
    processingState = ProcessingState.completed;
    _changes.add(null);
  }

  @override
  Future<void> prepareToPlay() async {}
  @override
  Future<void> load(Uri uri, Duration position) async =>
      this.position = position;
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> play({
    required void Function(Object, StackTrace) onError,
  }) async => playing = true;
  @override
  Future<void> pause() async => playing = false;
  @override
  Future<void> seek(Duration position) async => this.position = position;
  @override
  Future<void> stop() async => playing = false;
  @override
  Future<void> releaseFocus() async {}
  @override
  Future<void> dispose() => _changes.close();
}
