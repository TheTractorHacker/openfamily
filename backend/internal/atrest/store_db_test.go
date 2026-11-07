package atrest

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Needs TEST_DATABASE_URL (fresh migrated database).
func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	u := os.Getenv("TEST_DATABASE_URL")
	if u == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	p, err := pgxpool.New(context.Background(), u)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	return p
}

func TestLoadRewrapAndFailClosed(t *testing.T) {
	ctx := context.Background()
	pool := testPool(t)
	t.Cleanup(func() { SetDefault(nil); _, _ = pool.Exec(ctx, `DELETE FROM at_rest_keys`) })
	_, _ = pool.Exec(ctx, `DELETE FROM at_rest_keys`)
	SetDefault(nil)

	// No key, nothing stored: off, no error.
	t.Setenv("OPENFAMILY_DATA_KEY", "")
	t.Setenv("OPENFAMILY_DATA_KEY_FILE", "")
	if st, err := Load(ctx, pool); err != nil || st.Active || Enabled() {
		t.Fatalf("expected off: %+v %v", st, err)
	}
	// Key set: creates and stores a wrapped DEK, active.
	t.Setenv("OPENFAMILY_DATA_KEY", goodSecret)
	st, err := Load(ctx, pool)
	if err != nil || !st.Active || !Enabled() {
		t.Fatalf("expected active: %+v %v", st, err)
	}
	sealed, _ := Seal("t.c", "api-secret")
	var wrapped []byte
	if err := pool.QueryRow(ctx, `SELECT wrapped_dek FROM at_rest_keys`).Scan(&wrapped); err != nil || len(wrapped) < 40 {
		t.Fatal("wrapped dek not stored")
	}
	// Same key again opens the same DEK.
	SetDefault(nil)
	if _, err := Load(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if got, err := Open("t.c", sealed); err != nil || got != "api-secret" {
		t.Fatalf("value not readable after reload: %v", err)
	}
	// Wrong key: refuses.
	t.Setenv("OPENFAMILY_DATA_KEY", goodSecret+"WRONG")
	if _, err := Load(ctx, pool); err == nil {
		t.Fatal("wrong key accepted")
	}
	// Missing key while a DEK is stored: refuses (no silent downgrade).
	t.Setenv("OPENFAMILY_DATA_KEY", "")
	if _, err := Load(ctx, pool); err == nil || !strings.Contains(err.Error(), "OPENFAMILY_DATA_KEY") {
		t.Fatalf("missing key accepted: %v", err)
	}
	// Rotation: rewrap to a new key, old values stay readable, old key stops working.
	newKey := goodSecret + "-NEW"
	if err := Rewrap(ctx, pool, goodSecret, newKey); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OPENFAMILY_DATA_KEY", goodSecret)
	if _, err := Load(ctx, pool); err == nil {
		t.Fatal("old key still works after rewrap")
	}
	t.Setenv("OPENFAMILY_DATA_KEY", newKey)
	if _, err := Load(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if got, err := Open("t.c", sealed); err != nil || got != "api-secret" {
		t.Fatalf("value unreadable after rewrap: %v", err)
	}
	if err := Rewrap(ctx, pool, goodSecret, newKey); err == nil {
		t.Fatal("rewrap with the wrong current key succeeded")
	}
}
