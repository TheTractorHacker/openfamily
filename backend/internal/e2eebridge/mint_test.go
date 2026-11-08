package e2eebridge

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// tokenServer issues nothing itself: it accepts the tokens the test mints and
// refuses each one once it is older than ttl (by the fake clock), like the API
// does with an expired access token.
type tokenServer struct {
	mu        sync.Mutex
	now       *time.Time
	ttl       time.Duration
	issued    map[string]time.Time
	revoked   map[string]bool
	refuseAll bool
	got401    int
	requests  int
}

func (s *tokenServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requests++
	tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	at, ok := s.issued[tok]
	if s.refuseAll || !ok || s.revoked[tok] || s.now.Sub(at) >= s.ttl {
		s.got401++
		http.Error(w, `{"error":"invalid or expired token"}`, http.StatusUnauthorized)
		return
	}
	_, _ = w.Write([]byte(`[]`))
}

func newMintClient(t *testing.T, ttl, every time.Duration) (*apiClient, *tokenServer, *time.Time, *[]string) {
	t.Helper()
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	ts := &tokenServer{now: &now, ttl: ttl, issued: map[string]time.Time{}, revoked: map[string]bool{}}
	srv := httptest.NewServer(ts)
	t.Cleanup(srv.Close)
	c := newAPIClient(srv.URL, "", nil)
	n := 0
	c.mint = func(context.Context) (string, error) {
		ts.mu.Lock()
		defer ts.mu.Unlock()
		n++
		tok := fmt.Sprintf("tok-%d", n)
		ts.issued[tok] = now
		return tok, nil
	}
	c.mintMaxAge = every
	c.now = func() time.Time {
		ts.mu.Lock()
		defer ts.mu.Unlock()
		return now
	}
	logged := &[]string{}
	c.onStatus = func(method, path string, status int) {
		*logged = append(*logged, fmt.Sprintf("%s %s %d", method, path, status))
	}
	return c, ts, &now, logged
}

// The production symptom: every ~15 minutes the built-in device logged "the
// server answered its own device with an error ... status=401" because its
// minted token simply expired. Renewing ahead of the expiry means the API never
// sees an expired token, and nothing is logged.
func TestMintedTokenIsRenewedBeforeItExpires(t *testing.T) {
	c, ts, now, logged := newMintClient(t, 15*time.Minute, 5*time.Minute)
	ctx := context.Background()
	for i := 0; i < 12; i++ { // two hours of polling, every 10 minutes
		if err := c.do(ctx, http.MethodGet, "/circles", nil, nil); err != nil {
			t.Fatalf("poll %d: %v", i, err)
		}
		ts.mu.Lock()
		*now = now.Add(10 * time.Minute)
		ts.mu.Unlock()
	}
	if ts.got401 != 0 {
		t.Fatalf("the API answered %d requests with 401; the token must be renewed before it expires", ts.got401)
	}
	if len(*logged) != 0 {
		t.Fatalf("nothing should be logged, got %v", *logged)
	}
}

// A token the API refuses early (token_version bumped, secret rotated) is
// renewed once and the request retried; that routine renewal is not logged.
func TestRecoveredUnauthorizedIsNotLogged(t *testing.T) {
	c, ts, _, logged := newMintClient(t, 15*time.Minute, 5*time.Minute)
	ctx := context.Background()
	if err := c.do(ctx, http.MethodGet, "/circles", nil, nil); err != nil {
		t.Fatal(err)
	}
	ts.mu.Lock()
	ts.revoked[c.access] = true
	ts.mu.Unlock()
	if err := c.do(ctx, http.MethodGet, "/circles", nil, nil); err != nil {
		t.Fatalf("a revoked token must be replaced and the request retried: %v", err)
	}
	if ts.got401 != 1 || len(*logged) != 0 {
		t.Fatalf("got401=%d logged=%v; want one silent renewal", ts.got401, *logged)
	}
}

// A 401 that survives the renewal is a real problem (the account behind the
// server key cannot sign in): it is still logged, and the caller sees errReauth.
func TestPersistentUnauthorizedIsLogged(t *testing.T) {
	c, ts, _, logged := newMintClient(t, 15*time.Minute, 5*time.Minute)
	ts.refuseAll = true
	err := c.do(context.Background(), http.MethodGet, "/circles", nil, nil)
	if !errors.Is(err, errReauth) {
		t.Fatalf("err = %v, want errReauth", err)
	}
	if len(*logged) != 1 || (*logged)[0] != "GET /circles 401" {
		t.Fatalf("logged = %v, want exactly one 401 line", *logged)
	}
}

// Other error answers are still reported as before.
func TestOtherErrorsStillLogged(t *testing.T) {
	now := time.Now()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"nope"}`, http.StatusForbidden)
	}))
	defer srv.Close()
	c := newAPIClient(srv.URL, "", nil)
	c.mint = func(context.Context) (string, error) { return "t", nil }
	c.now = func() time.Time { return now }
	var logged []int
	c.onStatus = func(_, _ string, status int) { logged = append(logged, status) }
	if err := c.do(context.Background(), http.MethodGet, "/circles", nil, nil); err == nil {
		t.Fatal("want an error")
	}
	if len(logged) != 1 || logged[0] != http.StatusForbidden {
		t.Fatalf("logged = %v", logged)
	}
}
