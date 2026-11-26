# EasyPodcast server

Build with Go 1.27 and create a PostgreSQL database owned by a dedicated login role.
The role needs ordinary database-owner permissions. With a passwordless connection URL,
pgx reads the password from `PGPASSWORD` or a PostgreSQL password file. The
`TestPasswordlessDatabaseURL` integration test runs migrations using `PGPASSWORD`.

```sh
go build -o easypodcast .
export EASYPODCAST_DATABASE_URL='postgres://easypodcast@localhost/easypodcast?sslmode=disable'
./easypodcast migrate
./easypodcast user set-password listener
./easypodcast serve
```

| Variable | Default |
| --- | --- |
| `EASYPODCAST_DATABASE_URL` | Required PostgreSQL connection string |
| `EASYPODCAST_LISTEN` | `:8080` |
| `EASYPODCAST_REFRESH_INTERVAL` | `1h` (Go duration) |
| `EASYPODCAST_USER_AGENT` | `EasyPodcast/<version> (+https://github.com/jiri-one/easypodcast)` |
| `EASYPODCAST_TRUSTED_PROXIES` | Empty (comma-separated IPv4 or IPv6 CIDRs) |

- `serve` applies the migrations and starts HTTP and feed refresh. Use HTTPS at your reverse proxy for remote access.
- `healthcheck` sends `GET /health` to `127.0.0.1` on the port from `EASYPODCAST_LISTEN`. It exits silently with 0 on HTTP 200 and exits with 1 otherwise. The request times out after 3 seconds. The scratch image runs `/easypodcast healthcheck`.
- `migrate` applies embedded migrations. Run it before the setup and import commands.
- `user set-password <name>` creates the listener or changes their password. For automation, append `--password-stdin` and supply one line on standard input.
- `devices list` prints the ID, quoted device name, creation time and last seen time in UTC. Last seen starts at login and updates on authenticated requests. Unknown times for devices created before the upgrade appear as `-`.
- `devices revoke <id>` revokes that device's token immediately.
- `import-opml <file>` imports subscriptions and prints counts.
- `import-pinepods --pinepods-dsn <dsn> --pinepods-user <name>` reads PinePods 0.9.2 PostgreSQL, refreshes the subscriptions, and imports episode state and the queue. Use a read-only database login and a password file for the source. The command reports counts and can be run again before switching to EasyPodcast.

The login rate limit uses the direct peer's IP by default. When that peer is in a configured
trusted proxy CIDR, the server uses the final address in `X-Forwarded-For`. Caddy sends a single
client address. Invalid CIDRs are ignored, and an absent or malformed final address falls back
to the direct peer.

`GET /api/state`, `POST /api/state`, and `GET /api/episodes/{id}/state` carry `duration_ms`
as an integer or `null`. The duration comes from the player. A strictly newer state replaces
the entire record, including its duration. Requests that omit the field supply `null`.

The PinePods import matches by GUID, then by enclosure URL. Episodes missing from the feed are
created as `removed_from_feed` using the PinePods title, enclosure URL, GUID, publication date
and feed duration. Their listening states contribute to played counts. Imported states follow
the same newer-wins rule as the API and have `duration_ms: null`. The import fills the queue
only while its stored list is empty. PinePods timestamps without a time zone are interpreted as
UTC. A completion without its own date uses the listen date or one millisecond after the Unix
epoch when both dates are missing.

For a local API check, send the login JSON from a file with mode `0600`. It contains
`username`, `password`, and `device_name`. The following example uses `jq`.

```sh
token=$(curl -fsS http://localhost:8080/api/login \
  -H 'Content-Type: application/json' --data-binary @login.json | jq -er .token)
curl -fsS http://localhost:8080/api/state -H "Authorization: Bearer $token"
```

Run `go vet ./...` and `go test -race ./...`. Set `EASYPODCAST_TEST_DATABASE_URL` to a dedicated
test database. The test login needs permission to create a disposable role and database
for the migration privilege check.
