part of 'player.dart';

Future<void> connectMpris(EpisodePlayer player) async {
  final mpris = AudioServiceMpris.init(
    dBusName: 'easypodcast',
    identity: 'EasyPodcast',
    desktopEntry: 'one.jiri.easypodcast',
    canControl: true,
  );
  try {
    final handler = await AudioService.init(
      builder: () => _EpisodeAudioHandler(
        player,
        player._library,
        player._downloads,
        player._settings,
      ),
    );
    handler.mediaItem.map((item) => item != null).distinct().listen((loaded) {
      mpris.canPlay = loaded;
      mpris.canPause = loaded;
      mpris.canGoNext = loaded;
      mpris.canGoPrevious = loaded;
    });
  } on Exception catch (error) {
    debugPrint('EasyPodcast could not connect to MPRIS: $error');
  }
}
