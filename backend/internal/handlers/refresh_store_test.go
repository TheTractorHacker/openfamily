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

func (m *memRefreshStore) Rotate(_ context.Context, userID, oldJTI, newJTI string, exp time.Time) (rotateOutcome, error) {
	r, ok := m.rows[oldJTI]
	if !ok || r.user != userID {
		return rotateUnknown, nil
	}
	if !r.used && !r.revoked {
		if !time.Now().Before(r.expires) {
			return rotateUnknown, nil
		}
		r.used = true
		m.rows[newJTI] = &memRefreshRow{family: r.family, user: userID, expires: exp}
		return rotateOK, nil
	}
	for _, o := range m.rows {
		if o.family == r.family {
			o.revoked = true
		}
	}
	return rotateReused, nil
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
	if err := st.Create(ctx, uid, "pg-a", exp); err != nil {
		t.Fatal(err)
	}
	if out, err := st.Rotate(ctx, uid, "pg-a", "pg-b", exp); err != nil || out != rotateOK {
		t.Fatalf("rotate: %v %v", out, err)
	}
	// A retry right after the rotation (lost response) is tolerated and gets
	// a sibling token in the same family.
	if out, err := st.Rotate(ctx, uid, "pg-a", "pg-c", exp); err != nil || out != rotateOK {
		t.Fatalf("lost-response retry within grace: %v %v", out, err)
	}
	// The same spent token replayed after the grace window is theft.
	if _, err := pool.Exec(ctx, `UPDATE refresh_sessions SET used_at = now() - interval '5 minutes' WHERE jti = 'pg-a'`); err != nil {
		t.Fatal(err)
	}
	if out, err := st.Rotate(ctx, uid, "pg-a", "pg-c2", exp); err != nil || out != rotateReused {
		t.Fatalf("replay after grace: %v %v", out, err)
	}
	if out, err := st.Rotate(ctx, uid, "pg-b", "pg-d", exp); err != nil || out != rotateReused {
		t.Fatalf("family revoked: %v %v", out, err)
	}
	if out, _ := st.Rotate(ctx, uid, "missing", "pg-e", exp); out != rotateUnknown {
		t.Fatalf("unknown: %v", out)
	}
	if err := st.Purge(ctx); err != nil {
		t.Fatal(err)
	}
}
