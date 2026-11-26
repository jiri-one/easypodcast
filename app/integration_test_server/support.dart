import 'dart:convert';
import 'dart:io';

import 'package:easypodcast/core/sync.dart';
import 'package:easypodcast/data/data_layer.dart';
import 'package:easypodcast/data/default_sync_service.dart';
import 'package:easypodcast/data/http_api_client.dart';
import 'package:easypodcast/data/local_store.dart';
import 'package:easypodcast/data/sqflite_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const serverUrl = 'http://127.0.0.1:18080';
const fixtureServer = 'http://127.0.0.1:18081';
const feedUrl = '$fixtureServer/feed.xml';
const username = 'e2e';
const password = 'easypodcast-e2e';

final _run = DateTime.now().microsecondsSinceEpoch;
String fixture(String name) => '$feedUrl?case=$name-$_run';

class Exchange {
  Exchange(this.request, this.response);

  final http.BaseRequest request;
  final http.Response response;

  String get requestBody => request is http.Request
      ? utf8.decode((request as http.Request).bodyBytes)
      : '';

  dynamic get json => jsonDecode(utf8.decode(response.bodyBytes));

  String get trace {
    final requestHeaders = request.headers.map(
      (name, value) => MapEntry(
        name,
        name.toLowerCase() == 'authorization' ? 'Bearer <redacted>' : value,
      ),
    );
    var responseBody = utf8.decode(response.bodyBytes);
    if (request.url.path == '/api/login') {
      responseBody = responseBody.replaceFirstMapped(
        RegExp(r'("token"\s*:\s*)"[^"]*"'),
        (match) => '${match[1]}"<redacted>"',
      );
    }
    return '${request.method} ${request.url} $requestHeaders $requestBody\n'
        'HTTP ${response.statusCode} ${response.headers} $responseBody';
  }

  void expectStatus(int status) =>
      expect(response.statusCode, status, reason: trace);
}

class WireClient extends http.BaseClient {
  WireClient(this.name);

  final String name;
  final _client = http.Client();
  final exchanges = <Exchange>[];
  Future<void> Function(http.BaseRequest)? beforeSend;
  bool offline = false;

  Exchange get last => exchanges.last;

  void _trace(String message) {
    final path = Platform.environment['EASYPODCAST_E2E_TRACE'];
    if (path != null) {
      File(path).writeAsStringSync('[$name] $message\n', mode: FileMode.append);
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (offline) {
      _trace('${request.method} ${request.url} [offline]');
      throw const SocketException('simulated device outage');
    }
    await beforeSend?.call(request);
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    final exchange = Exchange(request, response);
    exchanges.add(exchange);
    _trace(exchange.trace);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _client.close();
}

class Device {
  Device(this.data, this.store, this.wire);

  final DataLayer data;
  final LocalStore store;
  final WireClient wire;

  DefaultSyncService get sync => data.sync as DefaultSyncService;

  static Future<Device> open(String name, DateTime Function() clock) async {
    final wire = WireClient(name);
    addTearDown(wire.close);
    final api = HttpApiClient(serverUrl: serverUrl, client: wire);
    final db = await LocalStore.open(databaseFactoryFfi, inMemoryDatabasePath);
    addTearDown(db.close);
    final store = LocalStore(db);
    final library = await SqfliteLibrary.open(store, api, clock: clock);
    addTearDown(library.dispose);
    final sync = DefaultSyncService(
      api: api,
      library: library,
      store: store,
      observeLifecycle: false,
      clock: clock,
    );
    api.onUnauthorized = sync.handleUnauthorized;
    addTearDown(() async {
      await sync.stop();
      sync.dispose();
    });
    await sync.login(
      serverUrl: serverUrl,
      username: username,
      password: password,
      deviceName: name,
    );
    await sync.start();
    final device = Device(
      DataLayer(api: api, library: library, sync: sync),
      store,
      wire,
    );
    await device.waitForSync();
    expect(
      sync.status.value.phase,
      SyncPhase.idle,
      reason: sync.status.value.error,
    );
    return device;
  }

  Future<void> waitForSync() {
    // ignore: invalid_use_of_visible_for_testing_member
    return sync.whenIdle();
  }

  Future<void> pauseAt(int id, int positionMs, {Duration? duration}) async {
    await data.library.prepareForPlayback(id);
    sync.setPlayingEpisode(id);
    try {
      await data.library.recordPosition(
        id,
        Duration(milliseconds: positionMs),
        duration: duration,
      );
    } finally {
      sync.setPlayingEpisode(null);
    }
    await waitForSync();
  }
}
