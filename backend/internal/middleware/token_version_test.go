package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/jackc/pgx/v5/pgxpool"
)

// A database failure must not look like an invalid session: clients sign the
// user out on 401, so an outage during a server update would log everyone out.
func TestRequireTokenVersionDBErrorIsNotUnauthorized(t *testing.T) {
	pool, err := pgxpool.New(context.Background(), "postgres://u:p@127.0.0.1:1/none?connect_timeout=1")
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	called := false
	h := RequireTokenVersion(pool)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true }))
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ctx = context.WithValue(ctx, claimsKey, &auth.Claims{UserID: "00000000-0000-0000-0000-000000000001", TokenVersion: 1})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/x", nil).WithContext(ctx))
	if rec.Code != http.StatusServiceUnavailable || called {
		t.Fatalf("status=%d called=%v, want 503 and no handler call", rec.Code, called)
	}
}
