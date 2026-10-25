package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pquerna/otp/totp"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
	"github.com/wheresfrank/openfamily/backend/internal/models"
	"github.com/wheresfrank/openfamily/backend/internal/sms"
)

func acctServer() *Server {
	return &Server{
		TM:        auth.NewTokenManager("test-secret-at-least-32-bytes-long!", time.Minute, time.Hour),
		AuthLimit: sms.NewLimiter(),
	}
}

func authedReq(method, path, body string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	return req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "u1"}))
}

// These requests are rejected before any database access, so a nil Pool is
// safe: a regression that reaches the DB would panic and fail the test.
func TestAccountHandlersRejectBadInputBeforeDB(t *testing.T) {
	long := strings.Repeat("a", auth.MaxPasswordLength+1)
	cases := []struct {
		name    string
		handler func(*Server) http.HandlerFunc
		req     *http.Request
		want    int
	}{
		{"setup no password", func(s *Server) http.HandlerFunc { return s.TOTPSetup }, authedReq("POST", "/", `{}`), 400},
		{"setup bad json", func(s *Server) http.HandlerFunc { return s.TOTPSetup }, authedReq("POST", "/", `{`), 400},
		{"setup unauthenticated", func(s *Server) http.HandlerFunc { return s.TOTPSetup }, httptest.NewRequest("POST", "/", nil), 401},
		{"enable bad json", func(s *Server) http.HandlerFunc { return s.TOTPEnable }, authedReq("POST", "/", `x`), 400},
		{"disable bad json", func(s *Server) http.HandlerFunc { return s.TOTPDisable }, authedReq("POST", "/", `x`), 400},
		{"change: missing fields", func(s *Server) http.HandlerFunc { return s.ChangePassword }, authedReq("POST", "/", `{}`), 400},
		{"change: same password", func(s *Server) http.HandlerFunc { return s.ChangePassword }, authedReq("POST", "/", `{"current_password":"abcdefgh","new_password":"abcdefgh"}`), 400},
		{"change: too short", func(s *Server) http.HandlerFunc { return s.ChangePassword }, authedReq("POST", "/", `{"current_password":"abcdefgh","new_password":"short"}`), 400},
		{"change: unauthenticated", func(s *Server) http.HandlerFunc { return s.ChangePassword }, httptest.NewRequest("POST", "/", nil), 401},
		{"reset: missing", func(s *Server) http.HandlerFunc { return s.ResetPassword }, httptest.NewRequest("POST", "/", strings.NewReader(`{"email":"a@b.c"}`)), 400},
		{"reset: weak password", func(s *Server) http.HandlerFunc { return s.ResetPassword }, httptest.NewRequest("POST", "/", strings.NewReader(`{"email":"a@b.c","code":"ABCDE","new_password":"x"}`)), 400},
		{"reset: huge password", func(s *Server) http.HandlerFunc { return s.ResetPassword }, httptest.NewRequest("POST", "/", strings.NewReader(`{"email":"a@b.c","code":"ABCDE","new_password":"`+long+`"}`)), 400},
		{"reset: bad json", func(s *Server) http.HandlerFunc { return s.ResetPassword }, httptest.NewRequest("POST", "/", strings.NewReader(`{`)), 400},
		{"delete: no body", func(s *Server) http.HandlerFunc { return s.DeleteMe }, authedReq("DELETE", "/", ""), 400},
		{"delete: empty password", func(s *Server) http.HandlerFunc { return s.DeleteMe }, authedReq("DELETE", "/", `{"password":""}`), 400},
		{"sessions: unauthenticated", func(s *Server) http.HandlerFunc { return s.ListSessions }, httptest.NewRequest("GET", "/", nil), 401},
		{"logout-all: unauthenticated", func(s *Server) http.HandlerFunc { return s.LogoutAll }, httptest.NewRequest("POST", "/", nil), 401},
		{"export: unauthenticated", func(s *Server) http.HandlerFunc { return s.ExportMe }, httptest.NewRequest("GET", "/", nil), 401},
		{"admin reset-code: unauthenticated", func(s *Server) http.HandlerFunc { return s.AdminIssueResetCode }, httptest.NewRequest("POST", "/", nil), 401},
		{"family reset-code: unauthenticated", func(s *Server) http.HandlerFunc { return s.FamilyIssueResetCode }, httptest.NewRequest("POST", "/", nil), 401},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			c.handler(acctServer())(rec, c.req)
			if rec.Code != c.want {
				t.Fatalf("status %d, want %d: %s", rec.Code, c.want, rec.Body.String())
			}
		})
	}
}

func TestStepUpThrottlesBeforeDB(t *testing.T) {
	s := acctServer()
	for i := 0; i < stepUpFailsPerUser; i++ {
		s.AuthLimit.Record("pwchange:fail:u1", stepUpFailsWindow)
	}
	rec := httptest.NewRecorder()
	if s.stepUp(rec, authedReq("POST", "/", ""), "u1", "whatever", "") || rec.Code != http.StatusTooManyRequests {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestLooksLikeTOTP(t *testing.T) {
	for in, want := range map[string]bool{
		"123456": true, " 123456 ": true, "12345": false, "1234567": false,
		"12345a": false, "ABCDE-FGHJK": false, "": false,
	} {
		if got := looksLikeTOTP(in); got != want {
			t.Errorf("%q: %v", in, got)
		}
	}
}

func TestDecoyRegistrationLooksLikeRealOne(t *testing.T) {
	fid := "f1"
	u := decoyRegistration("a@b.c", "A", &fid, models.RoleMember)
	if len(u.ID) != 36 || u.ID[14] != '4' || u.Email != "a@b.c" || u.Role != models.RoleMember || *u.FamilyID != "f1" {
		t.Fatalf("%+v", u)
	}
	if u.ID == decoyRegistration("a@b.c", "A", nil, models.RoleMember).ID {
		t.Fatal("decoy ids repeat")
	}
}

// BSEC-012: an unknown email must cost the same Argon2 work as a known one,
// which requires the dummy hash to carry the production parameters.
func TestDummyHashMatchesProductionParams(t *testing.T) {
	real, err := auth.HashPassword("x")
	if err != nil {
		t.Fatal(err)
	}
	params := func(h string) string { return strings.Join(strings.Split(h, "$")[1:4], "$") }
	if params(dummyPasswordHash()) != params(real) {
		t.Fatalf("dummy %q vs real %q", params(dummyPasswordHash()), params(real))
	}
	burnPasswordCheck("anything") // must not panic
}

func TestResetCodeFormatRoundTrip(t *testing.T) {
	raw, _ := auth.RandomCode(resetCodeLen)
	shown := auth.FormatCode(raw)
	if auth.NormalizeCode(strings.ToLower(shown)) != raw {
		t.Fatalf("%q does not normalize back to %q", shown, raw)
	}
}

// TestAccountFlowsPG runs the SQL against a real Postgres with migrations
// applied. Skipped unless TEST_DATABASE_URL is set.
func TestAccountFlowsPG(t *testing.T) {
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
	s := acctServer()
	s.Pool = pool

	email := "acct-" + time.Now().Format("150405.000000") + "@example.com"
	hash, _ := auth.HashPassword("old-password-1")
	var uid string
	if err := pool.QueryRow(ctx, `INSERT INTO users (email,name,password_hash) VALUES ($1,'t',$2) RETURNING id`, email, hash).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	defer pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, uid)

	t.Run("totp replay guard and recovery codes", func(t *testing.T) {
		secret := "JBSWY3DPEHPK3PXP"
		sealed, _ := auth.SealSecret(s.totpKey(), secret)
		codes, hashes, _ := s.newRecoveryCodes()
		if _, err := pool.Exec(ctx, `UPDATE users SET totp_secret=$2 WHERE id=$1`, uid, sealed); err != nil {
			t.Fatal(err)
		}
		now := time.Now()
		step, ok := auth.MatchTOTPStep(secret, mustCode(t, secret, now), now)
		if !ok {
			t.Fatal("no step")
		}
		if err := s.enableTOTP(ctx, uid, step, hashes); err != nil {
			t.Fatal(err)
		}
		if err := s.enableTOTP(ctx, uid, step, hashes); err != errTOTPRace {
			t.Fatalf("second enable: %v", err)
		}
		code := mustCode(t, secret, now)
		// The enrollment code's step is already spent.
		if s.verifySecondFactor(ctx, uid, sealed, code) {
			t.Fatal("enrollment code replayed at login")
		}
		// A newer step works exactly once.
		next := mustCode(t, secret, now.Add(30*time.Second))
		if !s.verifySecondFactor(ctx, uid, sealed, next) {
			t.Fatal("fresh code rejected")
		}
		if s.verifySecondFactor(ctx, uid, sealed, next) {
			t.Fatal("code accepted twice")
		}
		// Recovery codes: one use each, case/dash tolerant.
		if !s.verifySecondFactor(ctx, uid, sealed, strings.ToLower(codes[0])) {
			t.Fatal("recovery code rejected")
		}
		if s.verifySecondFactor(ctx, uid, sealed, codes[0]) {
			t.Fatal("recovery code reused")
		}
		if s.verifySecondFactor(ctx, uid, sealed, "ZZZZZ-ZZZZZ") {
			t.Fatal("bogus recovery code accepted")
		}
	})

	t.Run("reset code single use, expiry, wrong code", func(t *testing.T) {
		pool.Exec(ctx, `INSERT INTO refresh_sessions (jti,family_id,user_id,expires_at) VALUES ('rj1','rj1',$1,now()+interval '1 day')`, uid)
		shown, exp, err := s.issueResetCode(ctx, uid, uid)
		if err != nil || time.Until(exp) > resetCodeTTL || time.Until(exp) < resetCodeTTL-time.Minute {
			t.Fatalf("issue: %v exp=%v", err, exp)
		}
		code := auth.NormalizeCode(shown)
		if _, err := s.redeemResetCode(ctx, email, "AAAAAAAAAAAA", "new-password-1"); err != errBadResetCode {
			t.Fatalf("wrong code: %v", err)
		}
		if _, err := s.redeemResetCode(ctx, "nobody@example.com", code, "new-password-1"); err != errBadResetCode {
			t.Fatalf("unknown email: %v", err)
		}
		if id, err := s.redeemResetCode(ctx, email, code, "new-password-1"); err != nil || id != uid {
			t.Fatalf("redeem: %v %q", err, id)
		}
		if _, err := s.redeemResetCode(ctx, email, code, "new-password-2"); err != errBadResetCode {
			t.Fatalf("reuse: %v", err)
		}
		var h string
		var revoked bool
		pool.QueryRow(ctx, `SELECT password_hash FROM users WHERE id=$1`, uid).Scan(&h)
		pool.QueryRow(ctx, `SELECT revoked_at IS NOT NULL FROM refresh_sessions WHERE jti='rj1'`).Scan(&revoked)
		if ok, _ := auth.VerifyPassword("new-password-1", h); !ok || !revoked {
			t.Fatalf("password changed=%v sessions revoked=%v", ok, revoked)
		}
		// Expired code.
		shown, _, _ = s.issueResetCode(ctx, uid, uid)
		pool.Exec(ctx, `UPDATE password_reset_codes SET expires_at = now() - interval '1 second' WHERE user_id=$1`, uid)
		if _, err := s.redeemResetCode(ctx, email, auth.NormalizeCode(shown), "new-password-3"); err != errBadResetCode {
			t.Fatalf("expired: %v", err)
		}
		// Re-issuing replaces the previous unused code.
		first, _, _ := s.issueResetCode(ctx, uid, uid)
		s.issueResetCode(ctx, uid, uid)
		if _, err := s.redeemResetCode(ctx, email, auth.NormalizeCode(first), "new-password-4"); err != errBadResetCode {
			t.Fatalf("superseded code still works: %v", err)
		}
	})

	t.Run("session list and revoke", func(t *testing.T) {
		pool.Exec(ctx, `DELETE FROM refresh_sessions WHERE user_id=$1`, uid)
		exp := time.Now().Add(time.Hour)
		store := s.refreshSessions()
		store.Create(ctx, uid, "s1", exp)
		store.Create(ctx, uid, "s2", exp)
		pool.Exec(ctx, `UPDATE refresh_sessions SET user_agent='Phone' WHERE jti='s1'`)
		s.rotateRefreshToken(ctx, uid, "s1") // family s1 now has a used and a live token

		list := func() []sessionOut {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest("GET", "/", nil)
			req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
			s.ListSessions(rec, req)
			var out []sessionOut
			if rec.Code != 200 || json_decode(rec.Body.Bytes(), &out) != nil {
				t.Fatalf("list: %d %s", rec.Code, rec.Body.String())
			}
			return out
		}
		out := list()
		if len(out) != 2 {
			t.Fatalf("want 2 families, got %+v", out)
		}
		var sawPhone bool
		for _, o := range out {
			if o.ID == "s1" && o.UserAgent == "Phone" {
				sawPhone = true
			}
		}
		if !sawPhone {
			t.Fatalf("user agent lost across rotation: %+v", out)
		}
		router := chi.NewRouter()
		router.Delete("/auth/sessions/{id}", func(w http.ResponseWriter, r *http.Request) {
			s.RevokeSession(w, r.WithContext(middleware.ContextWithClaims(r.Context(), &auth.Claims{UserID: uid})))
		})
		for _, c := range []struct {
			id   string
			want int
		}{{"s2", 204}, {"s2", 404}, {"nope", 404}} {
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, httptest.NewRequest("DELETE", "/auth/sessions/"+c.id, nil))
			if rec.Code != c.want {
				t.Fatalf("revoke %s: %d", c.id, rec.Code)
			}
		}
		if len(list()) != 1 {
			t.Fatal("revoked family still listed")
		}
	})

	t.Run("export streams valid complete JSON; delete needs password", func(t *testing.T) {
		var did string
		if err := pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name, push_token) VALUES ($1,'android','Pixel','secret-push') RETURNING id`, uid).Scan(&did); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `INSERT INTO locations (device_id, ts, geom) VALUES ($1, now(), ST_SetSRID(ST_MakePoint(-122.4, 37.8), 4326))`, did); err != nil {
			t.Fatal(err)
		}
		as := func(r *http.Request) *http.Request {
			return r.WithContext(middleware.ContextWithClaims(r.Context(), &auth.Claims{UserID: uid}))
		}
		rec := httptest.NewRecorder()
		s.ExportMe(rec, as(httptest.NewRequest("GET", "/me/export", nil)))
		var doc struct {
			Profile  map[string]any   `json:"profile"`
			Devices  []map[string]any `json:"devices"`
			Locs     []map[string]any `json:"locations"`
			Count    int              `json:"location_count"`
			Complete bool             `json:"complete"`
		}
		if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &doc) != nil || !doc.Complete || doc.Count != 1 ||
			len(doc.Devices) != 1 || len(doc.Locs) != 1 || doc.Profile["email"] != email {
			t.Fatalf("export: %d %s", rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "secret-push") || strings.Contains(rec.Body.String(), "password") {
			t.Fatal("export leaks secrets")
		}
		// Third export within the hour is rate limited (limit is 2).
		s.ExportMe(httptest.NewRecorder(), as(httptest.NewRequest("GET", "/me/export", nil)))
		rec = httptest.NewRecorder()
		s.ExportMe(rec, as(httptest.NewRequest("GET", "/me/export", nil)))
		if rec.Code != 429 {
			t.Fatalf("export rate limit: %d", rec.Code)
		}

		// With TOTP on, the password alone is not enough to delete.
		rec = httptest.NewRecorder()
		s.DeleteMe(rec, as(httptest.NewRequest("DELETE", "/me", strings.NewReader(`{"password":"new-password-1"}`))))
		if rec.Code != 400 || !strings.Contains(rec.Body.String(), "totp_code") {
			t.Fatalf("delete without totp: %d %s", rec.Code, rec.Body.String())
		}
		pool.Exec(ctx, `UPDATE users SET totp_enabled = FALSE WHERE id = $1`, uid)

		// Account deletion: wrong password refused, right one deletes everything.
		for _, c := range []struct {
			body string
			want int
		}{{`{}`, 400}, {`{"password":"wrong-password"}`, 400}} {
			rec = httptest.NewRecorder()
			s.DeleteMe(rec, as(httptest.NewRequest("DELETE", "/me", strings.NewReader(c.body))))
			if rec.Code != c.want {
				t.Fatalf("delete %s: %d", c.body, rec.Code)
			}
		}
		s.AuthLimit.Reset("deleteme:user:" + uid) // the 3/hour cap counts every attempt
		rec = httptest.NewRecorder()
		s.DeleteMe(rec, as(httptest.NewRequest("DELETE", "/me", strings.NewReader(`{"password":"new-password-1"}`))))
		if rec.Code != 204 {
			t.Fatalf("delete: %d %s", rec.Code, rec.Body.String())
		}
		var n int
		pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM users WHERE id=$1) + (SELECT count(*) FROM devices WHERE id=$2) + (SELECT count(*) FROM locations WHERE device_id=$2)`, uid, did).Scan(&n)
		if n != 0 {
			t.Fatalf("%d rows survive deletion", n)
		}
	})
}

func mustCode(t *testing.T, secret string, at time.Time) string {
	t.Helper()
	c, err := totp.GenerateCode(secret, at)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func json_decode(b []byte, v any) error { return json.Unmarshal(b, v) }
