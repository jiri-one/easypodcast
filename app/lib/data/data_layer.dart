import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/api.dart';
import '../core/library.dart';
import '../core/settings.dart';
import '../core/sync.dart';
import 'default_sync_service.dart';
import 'http_api_client.dart';
import 'local_store.dart';
import 'sqflite_library.dart';

class DataLayer {
  const DataLayer({
    required this.api,
    required this.library,
    required this.sync,
  });

  final ApiClient api;
  final Library library;
  final SyncService sync;
}

Future<DataLayer> openDataLayer(Settings settings) async {
  final DatabaseFactory factory;
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    factory = databaseFactorySqflitePlugin;
  } else {
    sqfliteFfiInit();
    factory = databaseFactoryFfi;
  }
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  final db = await LocalStore.open(
    factory,
    p.join(directory.path, 'easypodcast.db'),
  );
  final store = LocalStore(db);
  final api = HttpApiClient(serverUrl: settings.serverUrl);
  final library = await SqfliteLibrary.open(store, api);
  api
    ..serverUrl = store.meta(MetaKey.serverUrl) ?? settings.serverUrl
    ..token = store.meta(MetaKey.token);
  final sync = DefaultSyncService(
    api: api,
    library: library,
    store: store,
    settings: settings,
  );
  api.onUnauthorized = sync.handleUnauthorized;
  return DataLayer(api: api, library: library, sync: sync);
}
