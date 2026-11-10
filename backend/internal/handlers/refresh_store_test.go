package handlers

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

// memRefreshStore mirrors pgRefreshStore's semantics in memory.
type memRefreshStore struct {
	rows map[string]*memRefreshRow
}

type memRefreshRow struct {
	family, user  string
	used, revoked bool
	expires       time.Time
}

func newMemRefreshStore() *memRefreshStore {
	return &memRefreshStore{rows: map[string]*memRefreshRow{}}
}

func (m *memRefreshStore) Create(_ context.Context, userID, jti string, exp time.Time) error {
	m.rows[jti] = &memRefreshRow{family: jti, user: userID, expires: exp}
	return nil
}

func (m *memRefreshStore) Rotate(_ context.Context, userID, oldJTI, newJTI string, exp time.Time) (rotateOutcome, string, error) {
	r, ok := m.rows[oldJTI]
	if !ok || r.user != userID {
		return rotateUnknown, "", nil
	}
	if !r.used && !r.revoked {
		if !time.Now().Before(r.expires) {
			return rotateUnknown, "", nil
		}
		r.used = true
		m.rows[newJTI] = &memRefreshRow{family: r.family, user: userID, expires: exp}
		return rotateOK, newJTI, nil
	}
	for _, o := range m.rows {
		if o.family == r.family {
			o.revoked = true
		}
	}
	return rotateReused, "", nil
}

func (m *memRefreshStore) Purge(context.Context) error { return nil }

func testRefreshServer() (*Server, *memRefreshStore) {
	st := newMemRefreshStore()
	return &Server{
		TM:           auth.NewTokenManager("test-secret-at-least-32-bytes-long!", time.Minute, time.Hour),
		RefreshStore: st,
	}, st
}

func TestRefreshRotationSingleUseAndReuseRevokesFamily(t *testing.T) {
	s, st := testRefreshServer()
	ctx := context.Background()
	first := "jti-1"
	_ = st.Create(ctx, "u1", first, time.Now().Add(time.Hour))

	second, status := s.rotateRefreshToken(ctx, "u1", first)
	if status != refreshRotated || second == "" || second == first {
		t.Fatalf("rotate: status=%v new=%q", status, second)
	}
	third, status := s.rotateRefreshToken(ctx, "u1", second)
	if status != refreshRotated {
		t.Fatalf("second rotate: status=%v", status)
	}

	// Replaying the first (already used) token is detected...
	if _, status := s.rotateRefreshToken(ctx, "u1", first); status != refreshReuse {
		t.Fatalf("replay: status=%v, want reuse", status)
	}
	// ...and revokes the whole family, including the newest legitimate token.
	if _, status := s.rotateRefreshToken(ctx, "u1", third); status != refreshReuse {
		t.Fatalf("family member after reuse: status=%v, want reuse/revoked", status)
	}
}

func TestRefreshRotationOtherFamilyUnaffected(t *testing.T) {
	s, st := testRefreshServer()
	ctx := context.Background()
	_ = st.Create(ctx, "u1", "phone", time.Now().Add(time.Hour))
	_ = st.Create(ctx, "u1", "tablet", time.Now().Add(time.Hour))
	next, _ := s.rotateRefreshToken(ctx, "u1", "phone")
	s.rotateRefreshToken(ctx, "u1", "phone") // replay on the phone family
	if _, status := s.rotateRefreshToken(ctx, "u1", "tablet"); status != refreshRotated {
		t.Fatalf("other device's session was killed: %v", status)
	}
	if _, status := s.rotateRefreshToken(ctx, "u1", next); status == refreshRotated {
		t.Fatal("revoked family still rotates")
	}
}

func TestRefreshRotationUnknownExpiredAndWrongUser(t *testing.T) {
	s, st := testRefreshServer()
	ctx := context.Background()
	if _, status := s.rotateRefreshToken(ctx, "u1", "never-issued"); status != refreshRejected {
		t.Fatalf("unknown jti: %v", status)
	}
	_ = st.Create(ctx, "u1", "old", time.Now().Add(-time.Minute))
	if _, status := s.rotateRefreshToken(ctx, "u1", "old"); status != refreshRejected {
		t.Fatalf("expired jti: %v", status)
	}
	_ = st.Create(ctx, "u1", "mine", time.Now().Add(time.Hour))
	if _, status := s.rotateRefreshToken(ctx, "u2", "mine"); status != refreshRejected {
		t.Fatalf("other user's jti: %v", status)
	}
}

// Tokens issued before rotation existed carry no jti: accepted once, then
// replaced by a tracked token.
func TestRefreshLegacyTokenMigrates(t *testing.T) {
	s, st := testRefreshServer()
	jti, status := s.rotateRefreshToken(context.Background(), "u1", "")
	if status != refreshRotated || jti == "" {
		t.Fatalf("legacy: status=%v jti=%q", status, jti)
	}
	if _, ok := st.rows[jti]; !ok {
		t.Fatal("legacy migration did not store the new token")
	}
}

func TestRefreshTokenCarriesJTI(t *testing.T) {
	tm := auth.NewTokenManager("test-secret-at-least-32-bytes-long!", time.Minute, time.Hour)
	tok, err := tm.IssueRefreshWithID("u1", "", 0, "abc123")
	if err != nil {
		t.Fatal(err)
	}
	c, err := tm.Parse(tok, auth.RefreshToken)
	if err != nil || c.ID != "abc123" {
		t.Fatalf("jti round trip: %v %+v", err, c)
	}
	legacy, _ := tm.IssueRefresh("u1", "", 0)
	if c, _ := tm.Parse(legacy, auth.RefreshToken); c == nil || c.ID != "" {
		t.Fatal("IssueRefresh must stay jti-less (legacy)")
	}
}

// TestPGRefreshStore exercises the SQL against a real Postgres that already
// has migrations applied. Skipped unless TEST_DATABASE_URL is set.
func TestPGRefreshStore(t *testing.T) {
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
	var uid string
	if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,'t','x') RETURNING id`,
		"rot-"+time.Now().Format("150405.000000")+"@example.com").Scan(&uid); err != nil {
		t.Fatal(err)
	}
	defer pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, uid)

	st := pgRefreshStore{pool}
	exp := time.Now().Add(time.Hour)
	// This test pins the strict once-per-token grace rules: the short idempotent window is off here
	// (see TestPGRefreshConcurrentPresentations for it).
	oldIdem := refreshIdempotentWindow
	refreshIdempotentWindow = 0
	t.Cleanup(func() { refreshIdempotentWindow = oldIdem })
	if err := st.Create(ctx, uid, "pg-a", exp); err != nil {
		t.Fatal(err)
	}
	if out, _, err := st.Rotate(ctx, uid, "pg-a", "pg-b", exp); err != nil || out != rotateOK {
		t.Fatalf("rotate: %v %v", out, err)
	}
	// A retry right after the rotation (lost response) is tolerated once and
	// gets a sibling token in the same family.
	if out, _, err := st.Rotate(ctx, uid, "pg-a", "pg-c", exp); err != nil || out != rotateOK {
		t.Fatalf("lost-response retry within grace: %v %v", out, err)
	}
	// ...but only once: a second replay of the same spent token is theft and
	// revokes the family, including the sibling just issued.
	if out, _, err := st.Rotate(ctx, uid, "pg-a", "pg-c2", exp); err != nil || out != rotateReused {
		t.Fatalf("second replay within grace: %v %v", out, err)
	}
	if out, _, err := st.Rotate(ctx, uid, "pg-c", "pg-c3", exp); err != nil || out != rotateReused {
		t.Fatalf("sibling after revoke: %v %v", out, err)
	}

	// A fresh family: replay after the grace window is theft.
	if err := st.Create(ctx, uid, "old-a", exp); err != nil {
		t.Fatal(err)
	}
	if out, _, err := st.Rotate(ctx, uid, "old-a", "old-b", exp); err != nil || out != rotateOK {
		t.Fatalf("rotate: %v %v", out, err)
	}
	if _, err := pool.Exec(ctx, `UPDATE refresh_sessions SET used_at = now() - interval '5 minutes' WHERE jti = 'old-a'`); err != nil {
		t.Fatal(err)
	}
	if out, _, err := st.Rotate(ctx, uid, "old-a", "old-c", exp); err != nil || out != rotateReused {
		t.Fatalf("replay after grace: %v %v", out, err)
	}

	// A replay is theft when the client already used the successor.
	if err := st.Create(ctx, uid, "ok-a", exp); err != nil {
		t.Fatal(err)
	}
	if out, _, _ := st.Rotate(ctx, uid, "ok-a", "ok-b", exp); out != rotateOK {
		t.Fatal("rotate ok-a")
	}
	if out, _, _ := st.Rotate(ctx, uid, "ok-b", "ok-c", exp); out != rotateOK {
		t.Fatal("rotate ok-b")
	}
	if out, _, err := st.Rotate(ctx, uid, "ok-a", "ok-d", exp); err != nil || out != rotateReused {
		t.Fatalf("replay after successor used: %v %v", out, err)
	}

	// Reset the family used by the remaining checks below.
	if err := st.Create(ctx, uid, "pg-x", exp); err != nil {
		t.Fatal(err)
	}
	if out, _, _ := st.Rotate(ctx, uid, "pg-x", "pg-y", exp); out != rotateOK {
		t.Fatal("rotate pg-x")
	}
	if out, _, err := st.Rotate(ctx, uid, "pg-b", "pg-d", exp); err != nil || out != rotateReused {
		t.Fatalf("family revoked: %v %v", out, err)
	}
	if out, _, err := st.Rotate(ctx, uid, "pg-y", "pg-z", exp); err != nil || out != rotateOK {
		t.Fatalf("unrelated family unaffected: %v %v", out, err)
	}
	if out, _, _ := st.Rotate(ctx, uid, "missing", "pg-e", exp); out != rotateUnknown {
		t.Fatalf("unknown: %v", out)
	}
	if err := st.Purge(ctx); err != nil {
		t.Fatal(err)
	}
}

// TestPGRefreshConcurrentPresentations: the screen, the background service and a retry of one phone present the
// same spent token within seconds. All of them get the SAME successor and nobody is signed out; after the window
// the strict rules apply again, and a used successor still makes a replay theft.
func TestPGRefreshConcurrentPresentations(t *testing.T) {
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
	var uid string
	if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,'t','x') RETURNING id`,
		"idem-"+time.Now().Format("150405.000000")+"@example.com").Scan(&uid); err != nil {
		t.Fatal(err)
	}
	defer pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, uid)
	st := pgRefreshStore{pool}
	exp := time.Now().Add(time.Hour)

	if err := st.Create(ctx, uid, "idem-a", exp); err != nil {
		t.Fatal(err)
	}
	out, got, err := st.Rotate(ctx, uid, "idem-a", "idem-b", exp)
	if err != nil || out != rotateOK || got != "idem-b" {
		t.Fatalf("first presentation: %v %q %v", out, got, err)
	}
	// Three more presentations of the same spent token, all within the window: same successor each time.
	for i, cand := range []string{"idem-c", "idem-d", "idem-e"} {
		out, got, err := st.Rotate(ctx, uid, "idem-a", cand, exp)
		if err != nil || out != rotateOK || got != "idem-b" {
			t.Fatalf("concurrent presentation %d: %v %q %v", i, out, got, err)
		}
	}
	// No orphan siblings were created.
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM refresh_sessions WHERE parent_jti = 'idem-a'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("children of idem-a: %d %v", n, err)
	}
	// The client uses the successor: the family moves on.
	if out, _, _ := st.Rotate(ctx, uid, "idem-b", "idem-f", exp); out != rotateOK {
		t.Fatal("rotate idem-b")
	}
	// A replay of idem-a once its successor was used is theft, even inside the window.
	if out, _, err := st.Rotate(ctx, uid, "idem-a", "idem-g", exp); err != nil || out != rotateReused {
		t.Fatalf("replay after the successor was used: %v %v", out, err)
	}
	// A replay after the window (and no strict grace left) is theft.
	if err := st.Create(ctx, uid, "late-a", exp); err != nil {
		t.Fatal(err)
	}
	if out, _, _ := st.Rotate(ctx, uid, "late-a", "late-b", exp); out != rotateOK {
		t.Fatal("rotate late-a")
	}
	// A phone that was frozen mid-refresh retries every ~15 s: still the same successor, never a fork or a revoke.
	if _, err := pool.Exec(ctx, `UPDATE refresh_sessions SET used_at = now() - interval '2 minutes' WHERE jti = 'late-a'`); err != nil {
		t.Fatal(err)
	}
	for i, cand := range []string{"late-x", "late-y", "late-z"} {
		if out, got, err := st.Rotate(ctx, uid, "late-a", cand, exp); err != nil || out != rotateOK || got != "late-b" {
			t.Fatalf("retry %d two minutes after the rotation: %v %q %v", i, out, got, err)
		}
	}
	if _, err := pool.Exec(ctx, `UPDATE refresh_sessions SET used_at = now() - interval '10 minutes' WHERE jti = 'late-a'`); err != nil {
		t.Fatal(err)
	}
	if out, _, err := st.Rotate(ctx, uid, "late-a", "late-c", exp); err != nil || out != rotateReused {
		t.Fatalf("replay long after the window: %v %v", out, err)
	}
}
