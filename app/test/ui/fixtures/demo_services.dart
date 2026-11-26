import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/core/settings.dart';
import 'package:easypodcast/player/player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_api.dart';
import 'demo_downloads.dart';
import 'demo_library.dart';
import 'demo_sync.dart';
import 'fake_playback_engine.dart';

Future<AppServices> createDemoServices({
  required FakePlaybackEngine engine,
  bool loggedIn = true,
  DemoLibrary? library,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await Settings.load();
  final catalog = library ?? DemoLibrary();
  final api = DemoApiClient(catalog);
  final sync = DemoSyncService(api, catalog, loggedIn: loggedIn);
  final downloads = DemoDownloadService(catalog, settings);
  return AppServices(
    settings: settings,
    api: api,
    library: catalog,
    sync: sync,
    player: EpisodePlayer(
      library: catalog,
      settings: settings,
      sync: sync,
      downloads: downloads,
      engine: engine,
    ),
    downloads: downloads,
  );
}
