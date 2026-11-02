package handlers

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func postCrash(h http.HandlerFunc, uid, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/crash-alerts", bytes.NewBufferString(body))
	if uid != "" {
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
	}
	w := httptest.NewRecorder()
	h(w, req)
	return w
}

func TestPostCrashAlertRejectsBadInput(t *testing.T) {
	s := &Server{}
	if w := postCrash(s.PostCrashAlert, "", `{}`); w.Code != http.StatusUnauthorized {
		t.Fatalf("no claims: %d", w.Code)
	}
	for name, body := range map[string]string{
		"bad json":  `{`,
		"bad lat":   `{"lat": 91, "lon": 4}`,
		"bad lon":   `{"lat": 1, "lon": 181}`,
		"neg g":     `{"peak_g": -1}`,
		"huge g":    `{"peak_g": 1e9}`,
		"huge spd":  `{"speed_before_mps": 5000}`,
		"neg after": `{"speed_after_mps": -3}`,
	} {
		if w := postCrash(s.PostCrashAlert, "u", body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: want 400, got %d", name, w.Code)
		}
	}
}

func TestPostCrashAlertStoresAndDedupes(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	if err := fx.srv.EnsureCrashSchema(ctx); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-20 * time.Second).UTC().Format(time.RFC3339Nano)
	body := `{"occurred_at":"` + at + `","lat":51.5,"lon":-0.12,"peak_g":8.5,` +
		`"speed_before_mps":18,"speed_after_mps":0.4,"help_requested":false}`

	w := postCrash(fx.srv.PostCrashAlert, fx.a, body)
	if w.Code != http.StatusCreated {
		t.Fatalf("first post: %d %s", w.Code, w.Body.String())
	}
	var n int
	var src string
	var help bool
	if err := fx.pool.QueryRow(ctx, `SELECT count(*), max(source), bool_or(help_requested) FROM crash_events WHERE user_id = $1`,
		fx.a).Scan(&n, &src, &help); err != nil {
		t.Fatal(err)
	}
	if n != 1 || src != "device" || help {
		t.Fatalf("stored: n=%d source=%s help=%v", n, src, help)
	}

	// A retry for the same crash is idempotent.
	if w := postCrash(fx.srv.PostCrashAlert, fx.a, body); w.Code != http.StatusOK {
		t.Fatalf("retry: %d %s", w.Code, w.Body.String())
	}
	// Help escalates the same row instead of creating a second one.
	helpBody := strings.Replace(body, `"help_requested":false`, `"help_requested":true`, 1)
	if w := postCrash(fx.srv.PostCrashAlert, fx.a, helpBody); w.Code != http.StatusOK {
		t.Fatalf("help: %d %s", w.Code, w.Body.String())
	}
	if err := fx.pool.QueryRow(ctx, `SELECT count(*), bool_or(help_requested) FROM crash_events WHERE user_id = $1`,
		fx.a).Scan(&n, &help); err != nil {
		t.Fatal(err)
	}
	if n != 1 || !help {
		t.Fatalf("after help: n=%d help=%v", n, help)
	}
}
