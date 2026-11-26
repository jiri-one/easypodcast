import 'package:flutter/widgets.dart';

import 'core/services.dart';
import 'core/settings.dart';
import 'data/data_layer.dart';
import 'downloads/downloads.dart';
import 'player/player.dart';
import 'ui/app_root.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final data = await openDataLayer(settings);
  final downloads = await openDownloads(
    library: data.library,
    settings: settings,
  );
  final player = await openPlayer(
    library: data.library,
    sync: data.sync,
    downloads: downloads,
    settings: settings,
  );
  await data.sync.start();
  runApp(
    EasyPodcastApp(
      services: AppServices(
        settings: settings,
        api: data.api,
        library: data.library,
        sync: data.sync,
        player: player,
        downloads: downloads,
      ),
    ),
  );
}
