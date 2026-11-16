//go:build integration

// Package integration_test exercises adapters against the LOCAL backing
// services declared in tests/env/.env.local (DATABASE_URL). Remote targets
// are refused unless TEST_LIVE=1 — see references/integration.md.
//
// Run:   make test-integration-go
// Bare:  go test -tags integration ./tests/integration/...
//
// The build tag keeps `go test ./...` green on a machine without the compose
// stack: without -tags integration this file is not compiled at all.
package integration_test

import (
	"context"
	"database/sql"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib" // driver name "pgx"

	"example.com/app/internal/testenv" // adjust to your module path
)

func TestItemsRepository_RoundTrip(t *testing.T) {
	env := testenv.Load(t)
	env.RequireLocal(t)

	db, err := sql.Open("pgx", env.DatabaseURL)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// One transaction per test, rolled back: the suite is idempotent and
	// parallel files never see each other's rows.
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	t.Cleanup(func() { _ = tx.Rollback() })

	name := "it-" + time.Now().Format("20060102T150405.000")
	var id string
	if err := tx.QueryRowContext(ctx, "INSERT INTO items(name) VALUES ($1) RETURNING id", name).Scan(&id); err != nil {
		t.Fatalf("insert: %v", err)
	}

	var got string
	if err := tx.QueryRowContext(ctx, "SELECT name FROM items WHERE id = $1", id).Scan(&got); err != nil {
		t.Fatalf("select: %v", err)
	}
	if got != name {
		t.Fatalf("round-trip: want %q, got %q", name, got)
	}
}
