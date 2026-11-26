part of 'player.dart';

Future<void> connectMpris(EpisodePlayer player) async {
  final mpris = AudioServiceMpris.init(
    dBusName: 'easypodcast',
    identity: 'EasyPodcast',
    desktopEntry: 'one.jiri.easypodcast',
    canControl: true,
    canPlay: true,
  );
  try {
    final handler = await AudioService.init(
      builder: () => EpisodeAudioHandler(
        player,
        player._library,
        player._downloads,
        player._settings,
        android: false,
      ),
    );
    handler.mediaItem.map((item) => item != null).distinct().listen((loaded) {
      mpris.canPause = loaded;
      mpris.canGoNext = loaded;
      mpris.canGoPrevious = loaded;
    });
  } on Exception catch (error) {
    debugPrint('EasyPodcast could not connect to MPRIS: $error');
  }
}
