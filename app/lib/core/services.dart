import 'api.dart';
import 'downloads.dart';
import 'library.dart';
import 'player.dart';
import 'settings.dart';
import 'sync.dart';

/// Built once in main.dart; the UI receives it and never constructs services itself.
class AppServices {
  const AppServices({
    required this.settings,
    required this.api,
    required this.library,
    required this.sync,
    required this.player,
    required this.downloads,
  });

  final Settings settings;
  final ApiClient api;
  final Library library;
  final SyncService sync;
  final PlayerController player;
  final DownloadService downloads;
}
