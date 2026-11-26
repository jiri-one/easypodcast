# EasyPodcast: architecture and contracts

Version 0.2 (after the specification review). Changes against 0.1: `duration_ms` in EpisodeState;
which time a state carries; the queue is written only by manual edits and hides played and
dismissed episodes; the server check also before resuming a paused episode; no position reports
after an end, dismiss or mark; bulk dismiss only for new episodes; states of episodes the client
does not have yet are kept; retries also on server errors and in the background; server device
commands, trusted proxy and a repeatable PinePods import.

This is the contract for the first build. Several agents work in parallel against it, so treat it
as binding: if you need to change it, say so in your report instead of silently diverging. The
product specification (in Czech) is `docs/specifikace.md`; this file turns it into interfaces.

EasyPodcast is a personal podcast system for one listener: a Go server on a small ARM64 home server
and a Flutter client for Android (two e-ink devices) and Linux. Episodes stream straight from the
publisher; the server keeps subscriptions, episode lists and listening state, and the client
keeps a local copy so that it works offline.

## Repository layout and ownership

| Path | Content | Owner |
|---|---|---|
| `server/` | Go module `github.com/jiri-one/easypodcast/server` | WP-S |
| `.github/workflows/server.yml` | server CI and image build | WP-S |
| `app/pubspec.yaml`, `app/lib/main.dart`, `app/lib/app.dart`, `app/lib/core/` | dependencies, entry point, shared models and interfaces | orchestrator |
| `app/lib/data/`, `app/test/data/` | API client, local database, repository, sync | WP-D |
| `app/lib/player/`, `app/lib/downloads/`, `app/test/player/`, `app/test/downloads/` | audio, notification, headset, Android Auto, downloads | WP-P |
| `app/android/`, `app/linux/`, `.github/workflows/app.yml` | platform configuration, app CI | WP-P |
| `app/lib/ui/`, `app/lib/l10n/`, `app/l10n.yaml`, `app/test/ui/` | screens, theme, texts | WP-U |
| `docs/` | specification, this contract, GUI mockups | orchestrator |

Rules for every agent:

- Edit only the paths you own. If something outside them blocks you, describe the change you
  need in your report.
- Do not run git commands that write (commit, checkout, switch, stash, reset, branch, merge,
  rebase, push). Reading (`git status`, `git diff`, `git log`) is fine. The orchestrator commits.
- `app/pubspec.yaml` already lists the planned packages. Do not edit it; if you need another
  package, finish what you can and name the package and the reason in your report.
- Comments and docstrings explain only a non-obvious why, in the shortest useful sentence. Never
  narrate what the code does.
- No secrets, home IP addresses or real personal data in the repository. Test data uses invented
  podcast names.
- Finish with a report: what you built, how to run and test it, what is missing or uncertain.

## Domain model

Identical in the server, the API and the client.

- **Podcast**: `id` (int), `feed_url`, `title`, `author`, `description` (plain text), `image_url`
  (nullable), `link` (nullable), `subscribed` (bool), `show_in_new_episodes` (bool, defaults to true),
  `episode_count` (int), `played_count`
  (int, episodes with status `played`), `episodes_version` (string, changes whenever the episode
  list of this podcast changes), `last_success_at` (nullable time), `last_error` (nullable string).
- **Episode**: `id` (int), `podcast_id`, `guid`, `title`, `published_at` (nullable time),
  `duration_s` (nullable int, from the feed, often wrong), `enclosure_url`, `enclosure_type`
  (nullable), `enclosure_length` (nullable int), `link` (nullable), `image_url` (nullable),
  `removed_from_feed` (bool). The description is fetched separately.
- **EpisodeState**: `episode_id`, `position_ms` (int ≥ 0), `status` (`""`, `"played"` or
  `"dismissed"`), `duration_ms` (nullable int: the duration measured by the player of the device
  that made the change, so other devices can show the remaining time), `updated_at` (the time the
  change happened, by the clock of the device that made it).
- **Queue**: `episode_ids` (ordered list of int), `updated_at` (time set by a device).

Times are RFC 3339 strings in UTC with milliseconds, for example `2026-11-26T14:03:07.120Z`.

Derived values, the same everywhere:

- **In progress** (rozposlouchaný): `status == ""` and `position_ms >= 60000`. Sorted by
  `updated_at`, newest first.
- **New** (nový): no state, or `status == ""` and `position_ms < 60000`.
- **Played** and **dismissed**: the status says so. Only `played` counts into `played_count`.
- **Queue as shown and played**: the stored `episode_ids` without played and dismissed episodes.
- An episode without a state behaves as `{position_ms: 0, status: ""}` with the oldest possible
  `updated_at`.

## Synchronisation rules

1. The server owns podcasts and episodes; ids come from the server. The client never parses feeds.
2. Every change made on a device produces a complete EpisodeState (or a complete Queue) whose
   `updated_at` is the moment the change happened on that device (listening sample, pause, seek,
   end, dismiss, mark). A pending change keeps its time when it is sent again. A state adopted from
   the server keeps the server's record and time and is never sent back. A new state of an episode
   always gets a later time than the device's previous state of it (add 1 ms on a tie).
3. A processed state or queue replaces a stored one only when its `updated_at` is strictly later.
   The server answers with the stored record either way.
4. The server skips records with `updated_at` more than 24 hours ahead of its clock and processes
   the rest. The 200 reply lists the skipped episode IDs and the literal `"queue"` for a skipped
   queue in `future`. The client keeps those changes pending, repairs their timestamps when it can,
   and retries them.
5. The client sends its pending changes (the latest state per episode, the latest queue) as soon as
   it can: on every pause including automatic ones (headphones unplugged, call, audio focus loss),
   on seek and skip, on completion, on any status or queue change, every 30 s while playing, and
   when the app goes to the background or closes. When sending fails (no network, timeout, 5xx)
   it keeps them and retries with backoff (5 s doubling to 5 min) for as long as the process
   lives, also in the background, and whenever the app starts or comes to the foreground. Before
   pulling, the client always sends what is pending.
6. The client fetches `GET /api/state` at start, when it comes to the foreground, after a successful
   send that followed an offline period, and every 15 minutes while in the foreground. It applies
   remote records with the same rule as the server (newer `updated_at` wins), except for the
   episode that is playing right now, whose position is never changed from outside.
7. Before playback of an episode starts, and before resuming or seeking an episode that has been
   paused for more than 30 s (from the app, the notification, the lock screen, a headset,
   Bluetooth or Android Auto), the client asks `GET /api/episodes/{id}/state` with a 2 s limit and
   applies a newer remote state first. If the remote state is played or dismissed, an automatic
   start (queue advance) skips the episode, and a start by the listener plays it from 0 as rule 9
   says. Without an answer in time it plays from the local state; its listening is then newer and
   wins, an accepted limitation.
8. Episode lists: the client compares `episodes_version` from `GET /api/podcasts` with its local
   copy and refetches `GET /api/podcasts/{id}/episodes` only for changed podcasts.
   New episodes includes only subscribed podcasts with `show_in_new_episodes` enabled. The client
   saves toggle changes locally and retries sending them through the pending changes sync. The
   most recent write accepted by the server sets the preference.
9. Transitions (all produce a new state with the device time):
   - playback reaches the end: `status = "played"`, `position_ms = 0`, and the next queue item
     starts (when the setting is on);
   - dismiss (not offered for played episodes): `status = "dismissed"`, `position_ms = 0`, every
     device deletes its download once it learns of it;
   - bulk dismiss "this and older": the same for every new episode of the podcast published up to
     the chosen one; in-progress, played and queued episodes are left alone;
   - mark as played: `status = "played"`, `position_ms = 0`;
   - return to new: `status = ""`, `position_ms = 0`;
   - starting a played or dismissed episode: `status = ""`, playback from 0.
   After an end, a dismiss or a mark the player sends no further position for that episode until
   it is started again; `Library.recordPosition` ignores episodes that are played or dismissed.
   None of these transitions writes the queue; the queue simply stops showing the episode.
10. "The end" means the player reports the completion of the stream. A pause, seek or periodic
    report near the end only records the position, so the outro is never cut; the listener can
    mark the episode played by hand. A sleep timer set to the end of the episode stops there,
    before the next queue item starts.
11. The queue is written only by manual edits (add, remove, move). Before such an edit the client
    refreshes the queue from the server when it can (2 s limit), so it edits the current list.
    Played and dismissed episodes drop out of the stored list at the next manual edit. Enqueueing
    a played or dismissed episode first returns it to new.
12. A state or a queue entry for an episode the client does not have yet is kept, never dropped;
    the client refreshes the podcasts and the changed episode lists to get the episode.

## HTTP API v1

Base URL `https://easypodcast.jiri.one/api` in production, `http://localhost:8080/api` locally.
JSON in UTF-8. Every endpoint except `POST /api/login` and `GET /health` needs
`Authorization: Bearer <token>`. Requests without a valid token get 401. Errors include
`{"error": "<message>"}` with status 400, 401, 404, 409, 413, 422, 429 or 500.

| Method and path | Request | Response |
|---|---|---|
| `POST /api/login` | `{"username", "password", "device_name"}` | 200 `{"token", "device_id", "server_id"}`, 401 for wrong credentials, 429 when the per-address or global login limit is reached |
| `POST /api/logout` | – | 204, revokes the token used |
| `GET /api/podcasts` | – | 200 `[Podcast]`: every podcast that is subscribed, has an episode with a state, or has an episode in the queue; supports `ETag`/`If-None-Match` |
| `POST /api/podcasts` | `{"feed_url"}` | 201 Podcast after a synchronous fetch (max 80 s overall), 200 if it existed (it is subscribed again), 422 if the URL is not a usable feed |
| `DELETE /api/podcasts/{id}` | – | 204, unsubscribes and keeps everything |
| `PUT /api/podcasts/{id}/new-episodes` | `{"show": false}` with optional `server_id` | 204, sets `show_in_new_episodes` and updates the podcast list's ETag when the value changes. 404 for an unknown podcast, 409 with the current `server_id` if the supplied UUID differs. |
| `GET /api/podcasts/{id}/episodes` | – | 200 `[Episode]`, newest first; `ETag` |
| `GET /api/podcasts/{id}/search` | `q` (at least two characters after trimming whitespace) | 200 `{"episode_ids": [episode IDs]}` in episode list order, up to 200. Every whitespace-separated term must occur in the title or plain-text description, ignoring case and diacritics. 400 for a missing or short query, 404 for a missing podcast. |
| `GET /api/search` | `q` (at least two characters after trimming whitespace) | 200 `{"episode_ids": [episode IDs]}` for subscribed podcasts, up to 100. Uses the same matching rules as podcast search. Sorts by publication date, newest first, with undated episodes last and higher IDs first when dates tie. 400 for a missing or short query. |
| `GET /api/episodes/{id}` | – | 200 Episode plus `"description"` (plain text, links written as URLs) |
| `GET /api/state` | Optional `If-None-Match` | 200 `{"episodes": [EpisodeState], "queue": Queue or null, "server_time", "server_id"}` with `ETag`, or 304 with an empty body when the validator matches |
| `POST /api/state` | `{"server_id": "<stored UUID>", "episodes": [EpisodeState], "queue": Queue}`, all fields optional | 200 `{"episodes": [EpisodeState as stored], "queue": Queue or null, "unknown": [episode IDs], "future": [episode IDs or "queue"], "server_id": "<current UUID>"}`. 409 `{"error": "server identity changed", "server_id": "<current UUID>"}` when the supplied UUID differs. |
| `GET /api/episodes/{id}/state` | – | 200 `{"state": EpisodeState or null}` |
| `POST /api/refresh` | – | 202, starts fetching all subscribed feeds now |
| `GET /api/opml` | – | 200 OPML of subscribed podcasts |
| `POST /api/opml` | OPML document as the body | 200 `{"added", "existing", "failed": [{"feed_url", "error"}]}` |
| `GET /health` | – | 200 `{"status": "ok"}` if the database is reachable and its recorded migrations match this binary, otherwise 503 |

On `POST /api/state`, an omitted or null `server_id` is accepted for older clients. A mismatch
aborts the transaction before any episode or queue writes. On 200, `episodes` echoes the stored
states for known episode records the server processed. `queue` always returns the stored queue
or `null`, including after a skipped queue update. `unknown` lists missing IDs from processed
episode states and queue entries. The client drops those pending episode changes unless the ID
also appears in `future`. Both lists are empty arrays when there are no entries. A body over 1 MiB
gets 413.

## Server (WP-S)

- Go 1.27 (the toolchain on the build PC is 1.27.4), standard `net/http` routing, `pgx` v5
  (`pgxpool`), `github.com/mmcdole/gofeed`, `golang.org/x/crypto/argon2` for passwords,
  `golang.org/x/net/html` to turn descriptions into plain text. Few other dependencies.
- Configuration from the environment: `EASYPODCAST_DATABASE_URL` (required),
  `EASYPODCAST_LISTEN` (default `:8080`), `EASYPODCAST_REFRESH_INTERVAL` (default `1h`),
  `EASYPODCAST_USER_AGENT` (default `EasyPodcast/<version> (+https://github.com/jiri-one/easypodcast)`).
- Commands of the single binary `easypodcast`: `serve` (runs migrations first), `migrate`,
  `user set-password <name>` (asks twice without echo, creates the user if missing; nothing is
  generated), `devices list`, `devices revoke <id>`, `devices revoke --all`, `new-server-id`,
  `import-opml <file>`, `import-pinepods` (see WP-S, part 2).
- Behind the reverse proxy every request comes from the proxy: the login limit uses the client
  address from `X-Forwarded-For` only when the direct peer is in `EASYPODCAST_TRUSTED_PROXIES`
  (comma-separated addresses or CIDRs, empty by default). It skips trusted addresses from the
  right and uses the first address outside the trusted set.
- PostgreSQL in a shared server: the role owns only its own database. Migrations must not need a
  superuser, extensions, `CREATE DATABASE` or the `postgres` database. Embedded SQL migrations
  with a `schema_migrations` table. A recorded migration unknown to the binary prevents startup.
- Server identity is a database UUID. After restoring a backup, run `new-server-id` before
  starting the server. Clients keep the UUID with their local copy, compare it on login and in
  state replies, and send it on each `POST /api/state`. The server checks the supplied UUID inside
  the state transaction. A 409 or a changed UUID tells the client to discard its local copy and
  pending changes and fetch all podcasts, episodes and state again. A 304 on `GET /api/state`
  confirms the UUID and state covered by the saved validator. The state validator changes when
  the UUID, an episode state, or the queue changes. `GET /api/state` provides `server_time` on 200.
- Single user: a `users` table exists only for the login; devices have their own tokens (32 random
  bytes, stored as SHA-256), revocable individually or together.
- Feeds: each subscribed podcast is fetched every refresh interval with jitter, at most 4 at a
  time, with `ETag`/`Last-Modified`; background refresh leaves a slot for subscription requests.
  Fetching and parsing share a 60-second budget. The decompressed size cap is 64 MiB, and only one
  response over 8 MiB is processed at a time. On errors the interval doubles up to 24 h. A permanent
  redirect updates `feed_url`. Items without an enclosure are skipped. Episodes are matched by
  GUID, without GUID by enclosure URL; changed fields are updated; episodes gone from the feed are
  marked `removed_from_feed`, never deleted. `episodes_version` changes with every change of the
  list. Feed order is stored per podcast to preserve the order of items with tied or missing dates.
- Description: HTML turned into plain text, a link written as `text (url)` when the text differs
  from the URL, at most 20 000 characters.
- Logs: plain text via `log/slog`. HTTP 500 logs include the method, route pattern, status and
  SQLSTATE when available.
- Container: multi-stage `server/Dockerfile`, static binary, non-root, CA certificates included,
  `linux/arm64` and `linux/amd64`. Image `ghcr.io/jiri-one/easypodcast`.
- CI `.github/workflows/server.yml` runs `go vet` and tests against PostgreSQL 18. It publishes a
  multi-arch image per qualifying ref, tagged `main` on the main branch or with the `v*` tag.
  The commit SHA identifies the binary version and image revision.
- Tests: the state rules (newer wins, equal or older ignored, identity conflicts, 24 h skips,
  unknown IDs), every endpoint with `httptest`, feed parsing fixtures (missing GUIDs, changed
  enclosure URLs, odd dates, HTML descriptions), and migrations on a real PostgreSQL when
  `EASYPODCAST_TEST_DATABASE_URL` is set (otherwise those tests skip).

## Client (Flutter)

- Flutter 3.50, Dart 3.14, `material_ui` (Material as a package, like the listener's other apps),
  Android and Linux. Android package `one.jiri.easypodcast`.
- Packages already in `pubspec.yaml`: `just_audio`, `audio_service`, `just_audio_media_kit` and
  `media_kit_libs_linux` (Linux audio), `sqflite` and `sqflite_common_ffi` (Linux), `path`,
  `path_provider`, `http`, `shared_preferences`, `background_downloader`, `url_launcher`, `intl`,
  `flutter_localizations`.
- State management as in the listener's apps: plain `ChangeNotifier` and `ValueNotifier`, no
  framework. One `AppServices` object built in `main.dart` holds the services.
- `app/lib/core/` holds the shared models and the interfaces below; the implementations live in
  the owners' folders. The UI depends only on `core/`.
- Texts in Czech and English via `flutter gen-l10n` (`app/lib/l10n/app_cs.arb`, `app_en.arb`).

### Interfaces in `app/lib/core/`

- `models.dart`: `Podcast`, `Episode`, `EpisodeState`, `QueueState`, `EpisodeStatus`, with
  `fromJson`/`toJson` matching the API.
- `api.dart`: `ApiClient`, one method per endpoint, throwing `ApiException` (with the HTTP status)
  or `OfflineException`.
- `library.dart`: `Library extends ChangeNotifier`, the local view of everything: podcasts, episodes
  of a podcast, in progress, queue, new episodes, downloaded episodes, and the commands
  (subscribe, unsubscribe, play bookkeeping, dismiss, mark played, return to new, enqueue,
  dequeue, move in queue). Commands change the local database at once and schedule a send.
- `sync.dart`: `SyncService` (start, stop, `syncNow()`, `freshStateBeforePlay(episodeId)`,
  `ValueListenable<SyncStatus>` for the UI).
- `player.dart`: `PlayerController extends ChangeNotifier` (current episode, playing, position,
  duration, speed, sleep timer; `play(episodeId)`, `pause()`, `seekBy`, `seekTo`, `setSpeed`,
  `setSleepTimer`).
- `downloads.dart`: `DownloadService extends ChangeNotifier` (`download`, `delete`,
  `statusOf(episodeId)`, `localFileOf(episodeId)`).
- `settings.dart`: `Settings` (server URL, device name, skip back/forward seconds, speed, keep
  screen updates sparse on e-ink) persisted in `shared_preferences`.

### Wiring

`main.dart` (orchestrator) builds the app from factories that the owners provide with exactly these
names and signatures:

```dart
final settings = await Settings.load();
final data = await openDataLayer(settings);                 // lib/data/data_layer.dart (WP-D)
final downloads = await openDownloads(                      // lib/downloads/downloads.dart (WP-P)
    library: data.library, settings: settings);
final player = await openPlayer(                            // lib/player/player.dart (WP-P)
    library: data.library, sync: data.sync, downloads: downloads, settings: settings);
await data.sync.start();
runApp(EasyPodcastApp(services: AppServices(               // lib/ui/app_root.dart (WP-U)
    settings: settings, api: data.api, library: data.library, sync: data.sync,
    player: player, downloads: downloads)));
```

- WP-D: `class DataLayer { final ApiClient api; final Library library; final SyncService sync; }`
  and `Future<DataLayer> openDataLayer(Settings settings)`.
- WP-P: `Future<DownloadService> openDownloads({required Library library, required Settings settings})`
  and `Future<PlayerController> openPlayer({required Library library, required SyncService sync,
  required DownloadService downloads, required Settings settings})`. The player plays the local file
  when `downloads.localFileOf(id)` is set, otherwise the enclosure URL; it calls
  `sync.freshStateBeforePlay`, then `library.prepareForPlayback`, reports through
  `library.recordPosition` and `library.markCompleted`, and tells `sync.setPlayingEpisode`. The
  download service listens to `library.finishedEpisodes` and deletes those files when
  `settings.deleteAfterPlayed` is on (dismissed episodes always).
- WP-U: `EasyPodcastApp` plus `lib/ui/demo/demo_main.dart`, an entry point with fake services and
  invented content, so the UI runs without a server: `flutter run -d linux -t lib/ui/demo/demo_main.dart`.

## Work packages

- **WP-S, server** (Codex): everything under `server/` and the server CI. Part 2, after the core
  works: `easypodcast import-pinepods`, an import from a PinePods 0.9.2 PostgreSQL database
  (subscriptions, episodes matched by GUID or enclosure URL, positions with their times, completed
  episodes as `played` with their times, the queue). It can run again before the switch from
  PinePods: states go through the same newer-wins rule, the queue is imported only while ours is
  empty, and PinePods episodes no longer in the feed are created with `removed_from_feed` so that
  their history and the played counts survive.
- **WP-D, data and sync** (Gemini): `app/lib/data/`: the API client, the local database (sqflite;
  `sqflite_common_ffi` on Linux), the `Library` and `SyncService` implementations, with unit tests
  of the rules above against a fake server.
- **WP-P, player and platform** (Codex): `app/lib/player/`, `app/lib/downloads/`, Android and Linux
  configuration: background playback with `audio_service` (notification, lock screen, headset and
  Bluetooth buttons, audio focus, becoming noisy), Android Auto browse tree (Rozposlouchané,
  Fronta, Stažené, Podcasty), skip back/forward in the car and on headsets, the position reports
  required by rule 5, completion and queue advance, downloads with `background_downloader`, Linux
  audio and MPRIS, app CI building the APK and the Linux bundle.
- **WP-U, user interface** (Claude): `app/lib/ui/` and texts, following the GUI mockup in
  `docs/gui/` and the e-ink rules in the specification (section 8.1), against the `core/`
  interfaces with fakes in widget tests.
- **Orchestrator** (Claude): this contract, `core/`, `main.dart`, integration, reviews, deployment
  to the home server, data import and installation on the devices.
