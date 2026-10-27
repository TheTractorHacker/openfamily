package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func TestInQuietHours(t *testing.T) {
	at := func(h, m int) time.Time { return time.Date(2026, 1, 5, h, m, 0, 0, time.UTC) }
	cases := []struct {
		now        time.Time
		tz         string
		start, end int
		want       bool
	}{
		{at(23, 0), "UTC", 22 * 60, 7 * 60, true},  // wraps midnight
		{at(3, 0), "UTC", 22 * 60, 7 * 60, true},
		{at(7, 0), "UTC", 22 * 60, 7 * 60, false},  // end exclusive
		{at(12, 0), "UTC", 22 * 60, 7 * 60, false},
		{at(12, 0), "UTC", 9 * 60, 17 * 60, true},  // same-day window
		{at(17, 0), "UTC", 9 * 60, 17 * 60, false},
		{at(23, 0), "Asia/Tokyo", 8 * 60, 9 * 60, true}, // 23:00 UTC = 08:00 JST
		{at(23, 0), "UTC+05:30", 4*60 + 30, 5*60 + 30, true}, // 04:30 local
		{at(23, 0), "UTC-08:00", 15 * 60, 16 * 60, true},     // 15:00 local
		{at(12, 0), "Not/AZone", 11 * 60, 13 * 60, true}, // bad tz falls back to UTC
	}
	for i, c := range cases {
		if got := inQuietHours(c.now, c.tz, c.start, c.end); got != c.want {
			t.Errorf("case %d: got %v want %v", i, got, c.want)
		}
	}
}

func (fx *alertFixture) prefsRouter() http.Handler {
	r := chi.NewRouter()
	r.Get("/members/{id}/notification-prefs", fx.srv.GetMemberNotificationPrefs)
	r.Put("/members/{id}/notification-prefs", fx.srv.PutMemberNotificationPrefs)
	r.Delete("/members/{id}/notification-prefs", fx.srv.DeleteMemberNotificationPrefs)
	return r
}

func (fx *alertFixture) prefs(method, subject, uid, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, "/members/"+subject+"/notification-prefs", strings.NewReader(body))
	if uid != "" {
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
	}
	w := httptest.NewRecorder()
	fx.prefsRouter().ServeHTTP(w, req)
	return w
}

func TestNotificationPrefsAuthorizationAndCRUD(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()

	// Unauthenticated, other family (no shared circle), self, bad id.
	if w := fx.prefs("GET", fx.b, "", ""); w.Code != 401 {
		t.Errorf("unauthenticated GET = %d", w.Code)
	}
	if w := fx.prefs("GET", fx.x, fx.a, ""); w.Code != 404 {
		t.Errorf("stranger GET = %d, want 404", w.Code)
	}
	if w := fx.prefs("PUT", fx.x, fx.a, `{"muted":true}`); w.Code != 404 {
		t.Errorf("stranger PUT = %d, want 404", w.Code)
	}
	if w := fx.prefs("DELETE", fx.x, fx.a, ""); w.Code != 404 {
		t.Errorf("stranger DELETE = %d, want 404", w.Code)
	}
	if w := fx.prefs("PUT", fx.a, fx.a, `{}`); w.Code != 400 {
		t.Errorf("self PUT = %d, want 400", w.Code)
	}
	if w := fx.prefs("GET", "nope", fx.a, ""); w.Code != 404 {
		t.Errorf("bad id GET = %d, want 404", w.Code)
	}

	// Defaults.
	w := fx.prefs("GET", fx.b, fx.a, "")
	if w.Code != 200 {
		t.Fatalf("GET %d %s", w.Code, w.Body)
	}
	var p notifPrefsJSON
	_ = json.Unmarshal(w.Body.Bytes(), &p)
	if p.Muted || !p.Arrivals || !p.Departures || !p.LowBattery || !p.Driving || !p.SOSAlwaysOn || p.QuietStart != nil {
		t.Errorf("defaults wrong: %+v", p)
	}

	// Validation.
	for _, bad := range []string{
		`{"quiet_start":"22:00"}`,
		`{"quiet_start":"25:00","quiet_end":"07:00"}`,
		`{"quiet_start":"07:00","quiet_end":"07:00"}`,
		`{"timezone":"Mars/Base"}`,
		`not json`,
	} {
		if w := fx.prefs("PUT", fx.b, fx.a, bad); w.Code != 400 {
			t.Errorf("PUT %s = %d, want 400", bad, w.Code)
		}
	}

	// Save (A about B) and read back; C's own view is independent.
	body := `{"arrivals":false,"departures":true,"low_battery":true,"driving":false,
		"quiet_start":"22:00","quiet_end":"07:00","timezone":"Europe/London","user_id":"` + fx.c + `"}`
	if w := fx.prefs("PUT", fx.b, fx.a, body); w.Code != 200 {
		t.Fatalf("PUT %d %s", w.Code, w.Body)
	}
	p = notifPrefsJSON{}
	w = fx.prefs("GET", fx.b, fx.a, "")
	_ = json.Unmarshal(w.Body.Bytes(), &p)
	if p.Arrivals || p.Driving || !p.Departures || p.QuietStart == nil || *p.QuietStart != "22:00" || p.Timezone != "Europe/London" {
		t.Errorf("round trip: %+v", p)
	}
	_ = json.Unmarshal(fx.prefs("GET", fx.b, fx.c, "").Body.Bytes(), &p)
	if !p.Arrivals {
		t.Errorf("C sees A's preferences: %+v", p)
	}
	var n int
	_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM member_notification_prefs WHERE user_id = $1`, fx.c).Scan(&n)
	if n != 0 {
		t.Errorf("body user_id must be ignored; C has %d rows", n)
	}

	// Reset.
	if w := fx.prefs("DELETE", fx.b, fx.a, ""); w.Code != 200 {
		t.Errorf("DELETE %d", w.Code)
	}
	_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM member_notification_prefs WHERE user_id = $1`, fx.a).Scan(&n)
	if n != 0 {
		t.Errorf("row not deleted")
	}
}

func TestNotificationPrefsDelivery(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	set := func(user, subject, cols, vals string) {
		t.Helper()
		if _, err := fx.pool.Exec(ctx, `INSERT INTO member_notification_prefs (user_id, subject_id, `+cols+`) VALUES ($1,$2,`+vals+`)
			ON CONFLICT (user_id, subject_id) DO NOTHING`, user, subject); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Date(2026, 1, 5, 23, 30, 0, 0, time.UTC)

	set(fx.b, fx.a, "arrivals", "false")             // B: no arrivals about A
	set(fx.c, fx.a, "muted", "true")                 // C: mutes A entirely
	set(fx.d, fx.a, "quiet_start, quiet_end", "1320, 420") // D: quiet 22:00-07:00 UTC

	arr := notifSuppressed(ctx, fx.pool, fx.a, notifArrivals, now)
	if !arr[fx.b] || !arr[fx.c] || !arr[fx.d] {
		t.Errorf("arrivals suppressed = %v", arr)
	}
	dep := notifSuppressed(ctx, fx.pool, fx.a, notifDepartures, now)
	if dep[fx.b] || !dep[fx.c] || !dep[fx.d] {
		t.Errorf("departures suppressed = %v", dep)
	}
	noon := time.Date(2026, 1, 5, 12, 0, 0, 0, time.UTC)
	if d := notifSuppressed(ctx, fx.pool, fx.a, notifDepartures, noon); d[fx.d] || !d[fx.c] {
		t.Errorf("quiet hours should end by noon: %v", d)
	}
	// Prefs about A never affect notifications about someone else.
	if o := notifSuppressed(ctx, fx.pool, fx.b, notifArrivals, now); len(o) != 0 {
		t.Errorf("leak across subjects: %v", o)
	}
	// SOS, help, check-in and unknown categories are never suppressed.
	for _, cat := range []string{"sos", "help", "check_in", "", "resolved"} {
		if s := notifSuppressed(ctx, fx.pool, fx.a, cat, now); len(s) != 0 {
			t.Errorf("category %q suppressed %v", cat, s)
		}
	}

	// End to end: with everyone muting A, an SOS from A still reaches B's device.
	if _, err := fx.pool.Exec(ctx, `UPDATE member_notification_prefs SET muted = true, arrivals = false WHERE subject_id = $1`, fx.a); err != nil {
		t.Fatal(err)
	}
	fx.srv.fanOutAlert(fx.newSOS(t), false)
	if len(fx.push.sent) != 1 {
		t.Errorf("SOS pushes = %d, want 1 despite mute-all", len(fx.push.sent))
	}
}
