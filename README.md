# EasyPodcast

EasyPodcast is a self-hosted podcast system for one listener: a small Go server and a Flutter app for Android and Linux. Episodes stream straight from the publisher (or download directly to Android for offline listening). The server keeps subscriptions, episode lists, listening positions, played and dismissed states, and the queue in PostgreSQL so phones and desktop stay in sync.

The interface is built for e-ink screens: black and white, no animations or touch ripples, large text, and outlines instead of shadows. It is available in English and Czech.

## Features

### Server

- **Single-listener authentication**: one account with Argon2id password hashing, per-device bearer tokens, CLI device listing and revocation, and per-IP and global login rate limits (with optional trusted-proxy `X-Forwarded-For` handling).
- **Subscriptions and OPML**: subscribe by RSS, Atom, or JSON Feed URL; unsubscribing stops refreshes while keeping stored episodes and listening history. Import and export OPML via the API or `import-opml`.
- **Scheduled feed refresh and status**: fetches subscribed feeds on a schedule (default `1h`, with jitter, `ETag`/`Last-Modified`, and backoff up to 24 h on failures) or on demand, reports each feed's last successful fetch and last error, blocks non-public feed addresses by default, converts HTML descriptions to plain text with links kept as URLs, and archives episodes removed from feeds instead of deleting them.
- **Cross-device sync**: stores positions, player-measured durations, played/dismissed states, and the queue; the newer device timestamp wins (including rewinding). Uses `ETag`/`If-None-Match` on state and episode lists, skips timestamps more than 24 h in the future, and tracks a server UUID (`new-server-id`) so clients reset cleanly after a backup restore.
- **Episode search**: search within one podcast or across all subscribed podcasts, matching all words against titles and plain-text descriptions while ignoring case and diacritics.
- **PinePods import**: repeatable `import-pinepods` command to import subscriptions, positions, played history (including episodes gone from feeds), and the queue from a PinePods 0.9.2 PostgreSQL database.
- **Health check and container**: `GET /health` verifies PostgreSQL reachability and migrations; published as a single static binary in a non-root `scratch` image for `linux/amd64` and `linux/arm64`.

See [server/README.md](server/README.md) for the full configuration, command, API, and limit reference.

### Android app

- **E-ink first UI**: black-and-white theme with no animations, large touch targets, sparse progress updates on the mini player, and grayscale cached podcast covers in lists and the player.
- **Library views**:
  - **In progress**: unfinished episodes past one minute, most recently listened first, with remaining time.
  - **Queue**: manually ordered list with long-press drag reordering and menu actions (move up, move down, move to top); played and dismissed episodes are hidden automatically, and auto-advance to the next queued episode can be toggled in Settings.
  - **New episodes**: new episodes from the last 30 days grouped by day, with manual refresh.
  - **Podcasts**: sorted by played count or alphabetically, with feed status, add-by-URL, and unsubscribe/resubscribe.
  - **Downloads**: offline files and total storage used.
- **Episode actions**: mark played or new, dismiss (hides from active lists and deletes downloads without counting as played), bulk "Dismiss older too" for new unqueued episodes, and plain-text episode descriptions with clickable links.
- **Search**: search inside a podcast or across all subscribed podcasts; title matching works offline and description matches are merged from the server, ignoring case and diacritics.
- **Offline downloads**: manual per-episode downloads plus Settings options for Wi-Fi-only downloads, automatic deletion after playback (dismissed episodes are always deleted), and keeping the first two queued episodes downloaded on Wi-Fi.
- **Player**: configurable skip back (10, 15, or 30 s) and skip forward (15, 30, or 60 s). Playback speed (0.8×–2.0×) and sleep timer (15, 30, 45, or 60 min, or end of episode) are hidden by default and enabled with one switch in Settings. Episodes are marked played only when playback reaches the actual end.
- **Offline cache and handoff**: local SQLite store caches the library and pending changes, checks the server for a newer position before starting playback or resuming after a pause longer than 30 s, and sends pending updates on pause, seek, completion, queue edits, periodically while playing, and on network recovery.
- **Audio, system, and car integration**: pauses and automatically resumes for notification sounds and navigation prompts instead of ducking speech; pauses and saves position when headphones unplug or another app takes audio focus; provides media notification and lock screen controls (without a seek bar to avoid accidental touches), Bluetooth headset buttons (play/pause, next/previous mapped to skip forward/back), and Android Auto (browse In progress, Queue, Downloads, and Podcasts; voice search by podcast title; works with the app closed).
- **OPML**: import and export subscriptions via the clipboard in Settings.

### Linux app

- **Same core app, desktop layout**: shares subscriptions, library views, search, queue drag reordering, OPML, and sync with the Android app. On wide windows, switches to a three-pane layout (navigation, list, episode detail) with a persistent bottom player bar and keyboard shortcuts (`Space` play/pause, `Left`/`Right` skip, `Up`/`Down` step through episodes in the wide view, `Escape` back).
- **Desktop integration**: audio playback via `libmpv`, media keys and status via MPRIS, and UI text sized and rendered with the system GTK font.
- **Differences from Android**: episodes stream straight from the publisher; offline downloads and the sleep timer are not included (playback speed is available when enabled in Settings).

## Self-hosting

The commands below use `docker`. If you use Podman, replace `docker` with `podman`. Examples use `podcasts.example.com`; replace it with your own domain.

### 1. Run PostgreSQL

Create a container network and a file with the database password (`chmod 600` so other users cannot read it):

```sh
docker network create easypodcast

cat > postgres.env <<'EOF'
POSTGRES_PASSWORD=replace-with-a-strong-password
EOF
chmod 600 postgres.env
```

Start PostgreSQL 18 with a persistent volume mounted at `/var/lib/postgresql` (the data directory layout used by the official `postgres:18` image):

```sh
docker run -d \
  --name easypodcast-db \
  --network easypodcast \
  --restart unless-stopped \
  -e POSTGRES_USER=easypodcast \
  -e POSTGRES_DB=easypodcast \
  --env-file ./postgres.env \
  -v easypodcast-pgdata:/var/lib/postgresql \
  docker.io/library/postgres:18

docker exec easypodcast-db pg_isready -U easypodcast -d easypodcast
```

Wait until `pg_isready` reports `accepting connections`. If you already run PostgreSQL (13 or newer), create a dedicated non-superuser login role and a database owned by that role instead. Migrations need no superuser permissions or extensions.

### 2. Run the server

Create an environment file for the server. With a passwordless `EASYPODCAST_DATABASE_URL`, `pgx` reads the password from `PGPASSWORD` (or a PostgreSQL password file via `PGPASSFILE`), keeping the password out of the URL:

```sh
cat > easypodcast.env <<'EOF'
EASYPODCAST_DATABASE_URL=postgres://easypodcast@easypodcast-db:5432/easypodcast?sslmode=disable
PGPASSWORD=replace-with-a-strong-password
EASYPODCAST_LISTEN=:8080
EASYPODCAST_TRUSTED_PROXIES=
EOF
chmod 600 easypodcast.env
```

Set `EASYPODCAST_TRUSTED_PROXIES` to the comma-separated IP address or CIDR that the EasyPodcast container sees as the direct peer from your reverse proxy (for example `127.0.0.1,::1` when running on the host network, or your bridge gateway / reverse-proxy container IP when bridged) so login rate limiting uses the client IP from `X-Forwarded-For`. See [server/README.md#configuration](server/README.md#configuration) and [server/README.md#reverse-proxy-and-rate-limiting](server/README.md#reverse-proxy-and-rate-limiting) for all variables and proxy rules.

The server keeps all state in PostgreSQL and needs no volumes of its own. Bind port `8080` to loopback and start `ghcr.io/jiri-one/easypodcast:main` (`serve` applies database migrations on startup):

```sh
docker run -d \
  --name easypodcast \
  --network easypodcast \
  --restart unless-stopped \
  --env-file ./easypodcast.env \
  -p 127.0.0.1:8080:8080 \
  ghcr.io/jiri-one/easypodcast:main
```

### 3. Check `/health`

```sh
curl -fsS http://127.0.0.1:8080/health
```

A healthy server with all migrations applied returns HTTP 200 and `{"status":"ok"}`.

### 4. Create the listener account

Run `user set-password <name>` inside the running container (the image is `FROM scratch`, so invoke `/easypodcast` directly):

```sh
docker exec -it easypodcast /easypodcast user set-password listener
```

For non-interactive scripts, pass `--password-stdin` and supply one line on standard input. EasyPodcast supports one user; running the command again for the same name updates the password without revoking existing device tokens.

### 5. Put the server behind HTTPS

Terminate TLS at a reverse proxy in front of `127.0.0.1:8080`. With Caddy:

```caddyfile
podcasts.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Reload Caddy and verify the public health endpoint:

```sh
curl -fsS https://podcasts.example.com/health
```

Remember to list the reverse proxy's peer address in `EASYPODCAST_TRUSTED_PROXIES` (step 2) and restart the server container after editing `easypodcast.env`.

### 6. Manage devices

List signed-in devices and revoke tokens individually or all at once:

```sh
docker exec easypodcast /easypodcast devices list
docker exec easypodcast /easypodcast devices revoke <id>
docker exec easypodcast /easypodcast devices revoke --all
```

To import subscriptions from OPML or migrate history from PinePods 0.9.2 from the command line, see [server/README.md#commands](server/README.md#commands) and [server/README.md#pinepods-import](server/README.md#pinepods-import).

### 7. Back up and restore the database

Back up PostgreSQL with `pg_dump`:

```sh
docker exec easypodcast-db pg_dump -U easypodcast easypodcast > "easypodcast-$(date -u +%Y%m%d).sql"
```

After restoring a backup into PostgreSQL, apply migrations and replace the server UUID before starting the server so apps discard stale local state and sync cleanly from the restored database:

```sh
docker run --rm --network easypodcast --env-file ./easypodcast.env \
  ghcr.io/jiri-one/easypodcast:main migrate
docker run --rm --network easypodcast --env-file ./easypodcast.env \
  ghcr.io/jiri-one/easypodcast:main new-server-id
```

### 8. Update the server

Take a database backup first, pull the new image, and recreate the container (`serve` applies any new migrations on startup; an older binary refuses to start against a newer schema):

```sh
docker pull ghcr.io/jiri-one/easypodcast:main
docker stop easypodcast
docker rm easypodcast
docker run -d \
  --name easypodcast \
  --network easypodcast \
  --restart unless-stopped \
  --env-file ./easypodcast.env \
  -p 127.0.0.1:8080:8080 \
  ghcr.io/jiri-one/easypodcast:main
```

### 9. Build and install the app

Build the app with Flutter `3.50.1` (Dart `^3.14.0`, pinned in [`.github/workflows/app.yml`](.github/workflows/app.yml)). See [app/README.md](app/README.md) for the short build reference.

#### Android

Requirements: Flutter `3.50.1`, Android SDK, JDK 17, and GNU `patch` (Gradle applies `app/android/audio_service.patch` automatically during the build).

To build a release APK signed with your own key (recommended so future updates install cleanly over older ones):

```sh
keytool -genkey -v \
  -keystore app/android/easypodcast.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias easypodcast

cat > app/android/key.properties <<'EOF'
storePassword=replace-with-store-password
keyPassword=replace-with-key-password
keyAlias=easypodcast
storeFile=easypodcast.jks
EOF
chmod 600 app/android/key.properties

cd app
flutter pub get
flutter build apk --release
```

`app/android/.gitignore` already ignores `key.properties` and `*.jks` files; keep your keystore backed up and out of version control. The signed APK is written to `app/build/app/outputs/flutter-apk/app-release.apk`.

To try the app without creating a release key, skip `key.properties` (`flutter build apk --release` falls back to the Android debug signing key) or build a debug APK with `flutter build apk --debug` (`app/build/app/outputs/flutter-apk/app-debug.apk`).

Install the APK on your phone (for example by transferring it to the device or running `adb install app/build/app/outputs/flutter-apk/app-release.apk` from the repository root). Because the APK is installed outside Google Play, using Android Auto requires enabling **Unknown sources** in Android Auto developer settings.

#### Linux

Install the Linux build libraries (on Debian/Ubuntu):

```sh
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
```

Build the release bundle:

```sh
cd app
flutter pub get
flutter build linux --release
```

The relocatable bundle is written to `app/build/linux/x64/release/bundle/` (or `arm64` on ARM64 Linux). Run `./build/linux/x64/release/bundle/easypodcast` from `app/`, or copy the bundle directory to a permanent location and install `share/applications/one.jiri.easypodcast.desktop` and `share/icons/` into `~/.local/share/`.

#### Sign in

Open the app on each device and enter:

- **Server address**: `https://podcasts.example.com`
- **Username**: `listener` (the name you passed to `user set-password`)
- **Password**: the password you set
- **Device name**: a label for this device (shown in `devices list`)

## Development

### Repository layout

- `server/` – Go server, embedded SQL migrations, and container `Dockerfile` ([server/README.md](server/README.md))
- `app/` – Flutter app for Android and Linux ([app/README.md](app/README.md))
- `tools/` – local end-to-end test runner (`tools/e2e-server.sh`)
- `branding/` – SVG app icons and generator script (`branding/generate.sh`)
- `docs/` – product specification in Czech ([docs/specifikace.md](docs/specifikace.md)), architecture and API contract ([docs/architecture.md](docs/architecture.md)), and GUI mockups ([docs/gui/navrh-gui.html](docs/gui/navrh-gui.html))
- `.github/workflows/` – CI workflows for server tests/container publishing and app checks/builds

### Running tests

Server (Go 1.27):

```sh
cd server
go vet ./...
go test -race ./...
```

Set `EASYPODCAST_TEST_DATABASE_URL` to a dedicated PostgreSQL test database (whose login can create a disposable role and database) to include the PostgreSQL integration tests; when unset, those tests skip.

App (Flutter 3.50.1):

```sh
cd app
flutter pub get
flutter analyze
flutter test
```

On Linux, after building with `flutter build linux --release`, you can also run the native desktop font parser test:

```sh
cd app
cmake -S linux -B build/linux/x64/release -DBUILD_TESTING=ON
cmake --build build/linux/x64/release --target desktop_font_test
ctest --test-dir build/linux/x64/release --output-on-failure
```

Server–client end-to-end tests (`tools/e2e-server.sh`):

```sh
./tools/e2e-server.sh --test
```

This script builds the server, resets the `easypodcast_e2e` database on a local test PostgreSQL listening on `127.0.0.1:55432` (user `easypodcast`, password `test`, database `easypodcast_test`, or a container named `easypodcast-test-pg` when `psql` is absent), serves a local fixture feed from `.ai/e2e/feed/feed.xml` on `127.0.0.1:18081`, starts the server on `127.0.0.1:18080`, and runs the Flutter integration suite in `app/integration_test_server/`. Without `--test`, it leaves the test server running for manual checks.

### Specification and contract

- [docs/specifikace.md](docs/specifikace.md) – product specification (in Czech)
- [docs/architecture.md](docs/architecture.md) – domain model, synchronization rules, and HTTP API contract

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
