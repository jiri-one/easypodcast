# EasyPodcast server

Build with Go 1.27 and create a PostgreSQL database owned by a dedicated login role.
The role needs ordinary database-owner permissions. Use environment configuration or a
PostgreSQL password file for credentials.

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

- `serve` applies the migrations and starts HTTP and feed refresh. Use HTTPS at your reverse proxy for remote access.
- `migrate` applies embedded migrations. Run it before the setup and import commands.
- `user set-password <name>` creates the listener or changes their password. For automation, append `--password-stdin` and supply one line on standard input.
- `import-opml <file>` imports subscriptions and prints counts.
- `import-pinepods --pinepods-dsn <dsn> --pinepods-user <name>` reads PinePods 0.9.2 PostgreSQL, refreshes the subscriptions, and imports matching episode state and the queue. Use a read-only database login and a password file for the source. Run before using the destination queue, since the imported queue receives the current time. PinePods timestamps without a time zone are interpreted as UTC. A completion without its own date uses the listen date or one millisecond after the Unix epoch when both dates are missing.

For a local API check, send the login JSON from a file with mode `0600`. It contains
`username`, `password`, and `device_name`. The following example uses `jq`.

```sh
token=$(curl -fsS http://localhost:8080/api/login \
  -H 'Content-Type: application/json' --data-binary @login.json | jq -er .token)
curl -fsS http://localhost:8080/api/state -H "Authorization: Bearer $token"
```

Run `go vet ./...` and `go test ./...`. Set `EASYPODCAST_TEST_DATABASE_URL` to a dedicated
test database. The test login needs permission to create a disposable role and database
for the migration privilege check.
