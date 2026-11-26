package main

import (
	"context"
	"crypto/rand"
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
	s := store{isolatedSchema(t)}
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
	s := store{pool}
	for range 2 {
		if err := s.migrate(t.Context()); err != nil {
			t.Fatal(err)
		}
	}
	var migrations int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM schema_migrations").Scan(&migrations); err != nil || migrations != 1 {
		t.Fatalf("migration count: %d, %v", migrations, err)
	}
}
