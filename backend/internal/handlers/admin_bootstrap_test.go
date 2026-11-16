package handlers

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The configured platform-admin email must not hand admin to whoever
// registered that address first: an existing account is promoted only when the
// configured secret matches its password.
func TestBootstrapPlatformAdminRequiresSecretForExistingAccount(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	srv := &Server{Pool: pool, hub: newHub()}

	email := "boot-" + time.Now().Format("150405.000000") + "@example.com"
	hash, _ := auth.HashPassword("attacker-chosen-pw-1")
	var id string
	if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,'x',$2) RETURNING id`, email, hash).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, id)
	isAdmin := func() bool {
		var a bool
		_ = pool.QueryRow(ctx, `SELECT platform_admin FROM users WHERE id=$1`, id).Scan(&a)
		return a
	}

	srv.BootstrapPlatformAdmin(ctx, email, "")
	if isAdmin() {
		t.Fatal("promoted without any configured secret")
	}
	srv.BootstrapPlatformAdmin(ctx, email, "operator-secret-9")
	if isAdmin() {
		t.Fatal("promoted although the secret does not match the account's password")
	}
	srv.BootstrapPlatformAdmin(ctx, email, "attacker-chosen-pw-1")
	if !isAdmin() {
		t.Fatal("not promoted although the configured secret matches")
	}
}
