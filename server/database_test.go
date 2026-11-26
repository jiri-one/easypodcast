package main

import (
	"context"
	"crypto/rand"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func integrationDatabase(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("EASYPODCAST_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("EASYPODCAST_TEST_DATABASE_URL is unset")
	}
	pool, err := pgxpool.New(t.Context(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := pool.Ping(t.Context()); err != nil {
		t.Fatal(err)
	}
	return pool
}

func testExec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(t.Context(), sql, args...); err != nil {
		t.Fatal(err)
	}
}

func isolatedSchema(t *testing.T) *pgxpool.Pool {
	t.Helper()
	parent := integrationDatabase(t)
	schema := "ep_test_" + strings.ToLower(rand.Text())
	ident := pgx.Identifier{schema}.Sanitize()
	testExec(t, parent, "CREATE SCHEMA "+ident)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := parent.Exec(ctx, "DROP SCHEMA "+ident+" CASCADE"); err != nil {
			t.Error(err)
		}
	})
	cfg := parent.Config()
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func integrationStore(t *testing.T) store {
	t.Helper()
	s := newStore(isolatedSchema(t))
	if err := s.migrate(t.Context()); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestMigrateAsDatabaseOwner(t *testing.T) {
	parent := integrationDatabase(t)
	name := "ep_owner_" + strings.ToLower(rand.Text())
	ident := pgx.Identifier{name}.Sanitize()
	password := rand.Text()
	testExec(t, parent, "CREATE ROLE "+ident+" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '"+password+"'")
	t.Cleanup(func() {
		if _, err := parent.Exec(context.Background(), "DROP ROLE "+ident); err != nil {
			t.Error(err)
		}
	})
	testExec(t, parent, "CREATE DATABASE "+ident+" OWNER "+ident)
	t.Cleanup(func() {
		if _, err := parent.Exec(context.Background(), "DROP DATABASE "+ident); err != nil {
			t.Error(err)
		}
	})
	cfg := parent.Config()
	cfg.ConnConfig.Database = name
	cfg.ConnConfig.User = name
	cfg.ConnConfig.Password = password
	pool, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	var super, canCreateDB bool
	err = pool.QueryRow(t.Context(), "SELECT rolsuper, rolcreatedb FROM pg_roles WHERE rolname = current_user").Scan(&super, &canCreateDB)
	if err != nil || super || canCreateDB {
		t.Fatalf("role privileges: super=%v createdb=%v, %v", super, canCreateDB, err)
	}
	s := newStore(pool)
	for range 2 {
		if err := s.migrate(t.Context()); err != nil {
			t.Fatal(err)
		}
	}
	var migrations int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM schema_migrations").Scan(&migrations); err != nil || migrations != 4 {
		t.Fatalf("migration count: %d, %v", migrations, err)
	}
}

func TestUpgradeInitialSchema(t *testing.T) {
	s := newStore(isolatedSchema(t))
	const initial = "migrations/001_initial.sql"
	sql, err := migrations.ReadFile(initial)
	if err != nil {
		t.Fatal(err)
	}
	testExec(t, s.db, string(sql))
	testExec(t, s.db, `
		CREATE TABLE schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
		INSERT INTO schema_migrations (version) VALUES ('migrations/001_initial.sql');
		INSERT INTO users (username, password_hash) VALUES ('listener', decode('00', 'hex'));
		INSERT INTO podcasts (feed_url) VALUES ('https://example.invalid/feed');
		INSERT INTO episodes (podcast_id, guid, title, enclosure_url, description)
			SELECT id, 'archive', 'Quiet Archive', 'https://example.invalid/archive.mp3', '' FROM podcasts;
		INSERT INTO episode_state (episode_id, position_ms, status, updated_at)
			SELECT id, 120000, '', '2025-10-01T08:10:00.123Z' FROM episodes;
	`)
	token, id, err := s.createDevice(t.Context(), "listener", "Legacy reader")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.migrate(t.Context()); err != nil {
		t.Fatal(err)
	}
	states, err := s.state(t.Context())
	if err != nil || len(states.Episodes) != 1 || states.Episodes[0].PositionMS != 120000 ||
		states.Episodes[0].DurationMS != nil || states.Episodes[0].UpdatedAt.UTC().Format(timestampLayout) != "2025-10-01T08:10:00.123Z" {
		t.Fatalf("existing state changed after upgrade: %+v, %v", states, err)
	}
	devices, err := s.devices(t.Context())
	if err != nil || len(devices) != 1 || devices[0].CreatedAt != nil || devices[0].LastSeenAt != nil {
		t.Fatal("legacy device dates should be unknown")
	}
	if got, err := s.deviceID(t.Context(), token); err != nil || got != id {
		t.Fatal("legacy device token stopped working")
	}
	devices, err = s.devices(t.Context())
	if err != nil || len(devices) != 1 || devices[0].CreatedAt != nil || devices[0].LastSeenAt == nil {
		t.Fatal("legacy device did not record last seen")
	}
}

func TestPasswordlessDatabaseURL(t *testing.T) {
	pool := isolatedSchema(t)
	original := pool.Config()
	u, err := url.Parse(original.ConnString())
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || original.ConnConfig.Password == "" {
		t.Skip("requires a PostgreSQL test URL with a test password")
	}
	u.User = url.User(original.ConnConfig.User)
	params := u.Query()
	params.Del("password")
	params.Set("search_path", original.ConnConfig.RuntimeParams["search_path"])
	u.RawQuery = params.Encode()
	t.Setenv("PGPASSWORD", original.ConnConfig.Password)
	t.Setenv("EASYPODCAST_DATABASE_URL", u.String())
	cfg, err := pgxpool.ParseConfig(u.String())
	if err != nil || cfg.ConnConfig.Password != original.ConnConfig.Password {
		t.Fatal("pgx did not use PGPASSWORD for the passwordless URL")
	}
	if err := run(t.Context(), []string{"migrate"}); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM schema_migrations").Scan(&count); err != nil || count != 4 {
		t.Fatalf("migration via PGPASSWORD: %d, %v", count, err)
	}
}
