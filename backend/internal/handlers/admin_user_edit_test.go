package handlers

import (
	"bytes"
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
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

type editEnv struct {
	t      *testing.T
	pool   *pgxpool.Pool
	rt     chi.Router
	ids    map[string]string
	emails map[string]string
	audit  []auditRow
}

func newEditEnv(t *testing.T) *editEnv {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	e := &editEnv{t: t, pool: pool, ids: map[string]string{}, emails: map[string]string{}}
	srv := &Server{Pool: pool, hub: newHub()}
	srv.auditHook = func(u, f, a, d string) { e.audit = append(e.audit, auditRow{u, f, a, d}) }

	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			if uid := req.Header.Get("X-Test-User"); uid != "" {
				req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
			}
			next.ServeHTTP(w, req)
		})
	})
	r.Group(func(r chi.Router) {
		r.Use(middleware.RequirePlatformAdmin(pool))
		r.Patch("/api/admin/users/{id}", srv.AdminUpdateUser)
		r.Patch("/api/admin/users/{id}/password", srv.AdminResetUserPassword)
	})
	e.rt = r

	prefix := "uedit-" + time.Now().Format("150405.000000")
	mk := func(key string, admin bool) {
		var id string
		em := prefix + "-" + key + "@example.com"
		if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash, platform_admin) VALUES ($1,$2,'x',$3) RETURNING id`,
			em, "User "+key, admin).Scan(&id); err != nil {
			t.Fatal(err)
		}
		e.ids[key], e.emails[key] = id, em
	}
	mk("admin", true)
	mk("admin2", true)
	mk("a", false)
	mk("b", false)
	if _, err := pool.Exec(ctx, `UPDATE users SET phone = '+15550001111' WHERE id = $1`, e.ids["b"]); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, id := range e.ids {
			_, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, id)
		}
		pool.Close()
	})
	return e
}

func (e *editEnv) patch(actor, target string, body any) (int, map[string]any) {
	e.t.Helper()
	b, _ := json.Marshal(body)
	id := e.ids[target]
	if id == "" {
		id = target
	}
	req := httptest.NewRequest(http.MethodPatch, "/api/admin/users/"+id, bytes.NewReader(b))
	req.Header.Set("X-Test-User", e.ids[actor])
	rec := httptest.NewRecorder()
	e.rt.ServeHTTP(rec, req)
	var m map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	return rec.Code, m
}

func TestAdminUpdateUserErrors(t *testing.T) {
	e := newEditEnv(t)
	long := strings.Repeat("x", 121)
	cases := []struct {
		name          string
		actor, target string
		body          map[string]any
		want          int
		errContains   string
	}{
		{"empty body", "admin", "a", map[string]any{}, 400, "provide"},
		{"blank name", "admin", "a", map[string]any{"name": "  "}, 400, "name"},
		{"long name", "admin", "a", map[string]any{"name": long}, 400, "name"},
		{"bad email", "admin", "a", map[string]any{"email": "nope"}, 400, "email"},
		{"bad phone", "admin", "a", map[string]any{"phone": "abc"}, 400, ""},
		{"email conflict", "admin", "a", map[string]any{"email": "USER-B"}, 409, "email"},
		{"phone conflict", "admin", "a", map[string]any{"phone": "+15550001111"}, 409, "phone"},
		{"not found", "admin", "00000000-0000-0000-0000-000000000000", map[string]any{"name": "Z"}, 404, "not found"},
		{"non-admin forbidden", "a", "b", map[string]any{"name": "Z"}, 403, ""},
		{"other platform admin email", "admin", "admin2", map[string]any{"email": "new-admin2@example.com"}, 403, "platform admin"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name == "email conflict" {
				tc.body["email"] = strings.ToUpper(e.emails["b"])
			}
			code, m := e.patch(tc.actor, tc.target, tc.body)
			if code != tc.want {
				t.Fatalf("got %d want %d: %v", code, tc.want, m)
			}
			msg, _ := m["error"].(string)
			if tc.errContains != "" && !strings.Contains(msg, tc.errContains) {
				t.Fatalf("error %q lacks %q", msg, tc.errContains)
			}
		})
	}
	if len(e.audit) != 0 {
		t.Fatalf("failed edits wrote audit rows: %v", e.audit)
	}
}

func TestAdminUpdateUserSuccess(t *testing.T) {
	e := newEditEnv(t)
	ctx := context.Background()

	newEmail := "  Renamed-" + e.emails["a"] + " "
	code, m := e.patch("admin", "a", map[string]any{"name": " New Name ", "email": newEmail, "phone": "+1 (555) 000-2222"})
	if code != 200 {
		t.Fatalf("got %d: %v", code, m)
	}
	if m["name"] != "New Name" || m["email"] != strings.ToLower(strings.TrimSpace(newEmail)) || m["phone"] != "+15550002222" {
		t.Fatalf("unexpected body: %v", m)
	}
	var tv int
	if err := e.pool.QueryRow(ctx, `SELECT token_version FROM users WHERE id=$1`, e.ids["a"]).Scan(&tv); err != nil || tv != 1 {
		t.Fatalf("token_version = %d err=%v, want 1 after email change", tv, err)
	}
	if len(e.audit) != 1 || e.audit[0].action != "admin.user_updated" || e.audit[0].user != e.ids["admin"] ||
		!strings.Contains(e.audit[0].detail, e.ids["a"]) || strings.Contains(e.audit[0].detail, "000-2222") {
		t.Fatalf("bad audit: %+v", e.audit)
	}

	// Name/phone only does not bump token_version; empty phone clears it.
	code, m = e.patch("admin", "a", map[string]any{"phone": "", "name": "Again"})
	if code != 200 || m["phone"] != nil {
		t.Fatalf("clear phone: %d %v", code, m)
	}
	if err := e.pool.QueryRow(ctx, `SELECT token_version FROM users WHERE id=$1`, e.ids["a"]).Scan(&tv); err != nil || tv != 1 {
		t.Fatalf("token_version = %d, want unchanged 1", tv)
	}

	// Same email (case-insensitive) is not a change.
	code, _ = e.patch("admin", "a", map[string]any{"email": strings.ToUpper(strings.TrimSpace(newEmail))})
	if code != 200 {
		t.Fatalf("same email: %d", code)
	}
	if err := e.pool.QueryRow(ctx, `SELECT token_version FROM users WHERE id=$1`, e.ids["a"]).Scan(&tv); err != nil || tv != 1 {
		t.Fatalf("token_version = %d, want 1", tv)
	}

	// Another platform admin's name/phone are editable; self email is allowed.
	if code, m = e.patch("admin", "admin2", map[string]any{"name": "Ops"}); code != 200 {
		t.Fatalf("edit admin2 name: %d %v", code, m)
	}
	if code, m = e.patch("admin", "admin", map[string]any{"email": "self-" + e.emails["admin"]}); code != 200 {
		t.Fatalf("self email: %d %v", code, m)
	}
}

// An admin email change cuts off everything the old identity held: refresh
// sessions, device ingest keys and public share links.
func TestAdminUpdateUserEmailRevokesCredentials(t *testing.T) {
	e := newEditEnv(t)
	ctx := context.Background()
	uid := e.ids["a"]
	seed := func() {
		must := func(_ any, err error) {
			if err != nil {
				t.Fatal(err)
			}
		}
		must(e.pool.Exec(ctx, `INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at) VALUES ($1,$1,$2, now()+interval '1 day')`, "jti-"+uid, uid))
		must(e.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, name, ingest_key_hash) VALUES ($1,'android','t','abc')`, uid))
		must(e.pool.Exec(ctx, `INSERT INTO share_links (user_id, token_hash, expires_at) VALUES ($1, decode(repeat('ab',32),'hex'), now()+interval '1 day')`, uid))
	}
	seed()
	if code, m := e.patch("admin", "a", map[string]any{"email": "rev-" + e.emails["a"]}); code != 200 {
		t.Fatalf("got %d: %v", code, m)
	}
	var live, keys, links int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM refresh_sessions WHERE user_id=$1 AND revoked_at IS NULL`, uid).Scan(&live)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id=$1 AND ingest_key_hash IS NOT NULL`, uid).Scan(&keys)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM share_links WHERE user_id=$1 AND revoked_at IS NULL`, uid).Scan(&links)
	if live != 0 || keys != 0 || links != 0 {
		t.Fatalf("after email change: sessions=%d ingest keys=%d share links=%d, want all 0", live, keys, links)
	}
}

func TestAdminResetPasswordRevokesCredentials(t *testing.T) {
	e := newEditEnv(t)
	ctx := context.Background()
	uid := e.ids["a"]
	for _, q := range []string{
		`INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at) VALUES ('jti-pw-` + uid + `','f',$1, now()+interval '1 day')`,
		`INSERT INTO devices (user_id, platform, name, ingest_key_hash) VALUES ($1,'android','t','abc')`,
		`INSERT INTO share_links (user_id, token_hash, expires_at) VALUES ($1, decode(repeat('cd',32),'hex'), now()+interval '1 day')`,
	} {
		if _, err := e.pool.Exec(ctx, q, uid); err != nil {
			t.Fatal(err)
		}
	}
	b, _ := json.Marshal(map[string]string{"password": "a-brand-new-password-1"})
	req := httptest.NewRequest(http.MethodPatch, "/api/admin/users/"+uid+"/password", bytes.NewReader(b))
	req.Header.Set("X-Test-User", e.ids["admin"])
	rec := httptest.NewRecorder()
	e.rt.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("got %d %s", rec.Code, rec.Body.String())
	}
	var live, keys, links int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM refresh_sessions WHERE user_id=$1 AND revoked_at IS NULL`, uid).Scan(&live)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id=$1 AND ingest_key_hash IS NOT NULL`, uid).Scan(&keys)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM share_links WHERE user_id=$1 AND revoked_at IS NULL`, uid).Scan(&links)
	if live != 0 || keys != 0 || links != 0 {
		t.Fatalf("after admin reset: sessions=%d ingest keys=%d share links=%d, want all 0", live, keys, links)
	}
}
