import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import 'demo_api.dart';
import 'demo_downloads.dart';
import 'demo_library.dart';
import 'demo_player.dart';
import 'demo_sync.dart';

Future<AppServices> createDemoServices() async {
  // The demo shares the Settings API while keeping preferences in memory.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'serverUrl': 'https://podcast.example',
    'deviceName': 'Demo',
  });
  final settings = await Settings.load();
  final library = DemoLibrary();
  final api = DemoApiClient(library);
  final sync = DemoSyncService(api, library, settings);
  return AppServices(
    settings: settings,
    api: api,
    library: library,
    sync: sync,
    player: DemoPlayerController(library, settings, sync),
    downloads: DemoDownloadService(library, settings),
  );
}
