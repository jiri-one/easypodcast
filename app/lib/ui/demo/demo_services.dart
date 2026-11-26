import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import 'demo_api.dart';
import 'demo_downloads.dart';
import 'demo_library.dart';
import 'demo_player.dart';
import 'demo_sync.dart';

Future<AppServices> createDemoServices({
  bool loggedIn = true,
  DemoLibrary? library,
}) async {
  // The demo shares the Settings API while keeping preferences in memory.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    if (loggedIn) 'serverUrl': 'https://podcast.example',
    if (loggedIn) 'deviceName': 'Demo',
  });
  final settings = await Settings.load();
  final catalog = library ?? DemoLibrary();
  final api = DemoApiClient(catalog);
  final sync = DemoSyncService(api, catalog, settings, loggedIn: loggedIn);
  return AppServices(
    settings: settings,
    api: api,
    library: catalog,
    sync: sync,
    player: DemoPlayerController(catalog, settings, sync),
    downloads: DemoDownloadService(catalog, settings),
  );
}
