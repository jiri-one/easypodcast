import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/api.dart';
import '../core/library.dart';
import '../core/sync.dart';
import 'default_sync_service.dart';
import 'http_api_client.dart';
import 'local_store.dart';
import 'sqflite_library.dart';

typedef DataLayer = ({ApiClient api, Library library, SyncService sync});

Future<DataLayer> openDataLayer() async {
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
  final api = HttpApiClient();
  final library = await SqfliteLibrary.open(store, api);
  api
    ..serverUrl = store.meta(MetaKey.serverUrl) ?? ''
    ..token = store.meta(MetaKey.token);
  final sync = DefaultSyncService(api: api, library: library, store: store);
  api.onUnauthorized = sync.handleUnauthorized;
  return (api: api, library: library, sync: sync);
}
