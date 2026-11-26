#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

if [[ $# -gt 1 || ( $# -eq 1 && $1 != --test ) ]]; then
  fail "Usage: $0 [--test]"
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work="$root/.ai/e2e"
feed="$root/tools/e2e-feed"
logs="$work/logs"
binary="$work/bin/easypodcast"
mkdir -p "$work/bin" "$logs"
exec 9>"$work/run.lock"
flock -n 9 || fail 'An EasyPodcast end-to-end run is already active.'
[[ -r "$feed/feed.xml" ]] || fail "Fixture feed is missing: $feed/feed.xml"

python3 - <<'PY'
import socket

for port in (18080, 18081):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError as error:
            raise SystemExit(f"Cannot bind 127.0.0.1:{port}: {error.strerror}")
PY

feed_pid=
server_pid=
test_pid=
cleanup() {
  if [[ -n "$test_pid" ]]; then
    kill -- "-$test_pid" 2>/dev/null || kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
  fi
  for pid in "$server_pid" "$feed_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$server_pid" "$feed_pid"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

reset_database() {
  local -a client
  if command -v psql >/dev/null; then
    client=(env PGPASSWORD=test PGSSLMODE=disable PGCONNECT_TIMEOUT=5 psql -p 55432)
  else
    client=(podman exec -i --env PGPASSWORD=test --env PGSSLMODE=disable
      --env PGCONNECT_TIMEOUT=5 easypodcast-test-pg psql -p 5432)
  fi
  "${client[@]}" -X -w -h 127.0.0.1 -U easypodcast -d easypodcast_test \
    -v ON_ERROR_STOP=1 <<'SQL'
DROP DATABASE IF EXISTS easypodcast_e2e;
CREATE DATABASE easypodcast_e2e;
SQL
}

export EASYPODCAST_DATABASE_URL='postgres://easypodcast:test@127.0.0.1:55432/easypodcast_e2e?sslmode=disable'
export EASYPODCAST_LISTEN='127.0.0.1:18080'
export EASYPODCAST_REFRESH_INTERVAL=1h
export EASYPODCAST_TRUSTED_PROXIES=''
export EASYPODCAST_ALLOW_PRIVATE_FEEDS=true
export no_proxy="127.0.0.1${no_proxy:+,$no_proxy}"

setup_log="$logs/setup.log"
(cd -- "$root/server" && go build -o "$binary" .) 9>&- >"$setup_log" 2>&1 ||
  fail "Server build failed. See $setup_log"
reset_database 9>&- >>"$setup_log" 2>&1 || fail "Test database reset failed. See $setup_log"
"$binary" migrate 9>&- >>"$setup_log" 2>&1 || fail "Migration failed. See $setup_log"
"$binary" user set-password e2e --password-stdin 9>&- <<< 'easypodcast-e2e' >>"$setup_log" 2>&1 ||
  fail "Test user setup via --password-stdin failed. See $setup_log"

wait_for_http() {
  local pid=$1 url=$2 log=$3 attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    kill -0 "$pid" 2>/dev/null || fail "Process serving $url exited. See $log"
    if curl --noproxy '*' --silent --fail --max-time 1 "$url" >/dev/null; then
      return
    fi
    sleep 0.1
  done
  fail "Timed out waiting for $url. See $log"
}

python3 -m http.server 18081 --bind 127.0.0.1 --directory "$feed" 9>&- >"$logs/feed.log" 2>&1 &
feed_pid=$!
wait_for_http "$feed_pid" 'http://127.0.0.1:18081/feed.xml' "$logs/feed.log"
"$binary" serve 9>&- >"$logs/server.log" 2>&1 &
server_pid=$!
wait_for_http "$server_pid" 'http://127.0.0.1:18080/health' "$logs/server.log"
printf 'EasyPodcast ready at http://127.0.0.1:18080\n'

if [[ ${1:-} == --test ]]; then
  export EASYPODCAST_E2E_BINARY="$binary"
  export EASYPODCAST_E2E_TRACE="$logs/http.log"
  : >"$EASYPODCAST_E2E_TRACE"
  (
    # Flutter classifies this path as device tests when invoked from app/.
    cd -- "$root/app/integration_test_server"
    exec setsid flutter test --no-pub --reporter expanded .
  ) 9>&- >"$logs/flutter.log" 2>&1 &
  test_pid=$!
  status=0
  wait "$test_pid" || status=$?
  cat "$logs/flutter.log"
  exit "$status"
fi

wait -n "$server_pid" "$feed_pid" || true
fail "An HTTP server exited. See $logs"
