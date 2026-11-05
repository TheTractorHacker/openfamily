package handlers

import (
	"context"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
)

func TestNameIf(t *testing.T) {
	if got := nameIf(false, "Henry Smith"); got != "A family member" {
		t.Fatalf("got %q", got)
	}
	if got := nameIf(true, "Henry Smith"); got != "Henry" {
		t.Fatalf("got %q", got)
	}
}

func TestCrashAndChatCopyHonourShow(t *testing.T) {
	for _, kind := range []string{"", "device", "device_help"} {
		ti, bo := crashCopy(nameIf(false, "Henry Smith"), kind)
		if strings.Contains(ti+bo, "Henry") {
			t.Fatalf("crash copy leaks name: %q %q", ti, bo)
		}
		ti, bo = crashCopy(nameIf(true, "Henry Smith"), kind)
		if !strings.Contains(ti+bo, "Henry") {
			t.Fatalf("crash copy missing name: %q %q", ti, bo)
		}
	}
	msg := chatMessageOut{SenderName: "Henry", Body: "secret plan"}
	if ti, bo := chatPushCopy(false, "Fam", msg); strings.Contains(ti+bo, "Henry") || strings.Contains(ti+bo, "secret") {
		t.Fatalf("chat leaks: %q %q", ti, bo)
	}
	if _, bo := chatPushCopy(true, "Fam", msg); bo != "Henry: secret plan" {
		t.Fatalf("chat body %q", bo)
	}
}

func TestDriveBodyUnits(t *testing.T) {
	if got := driveBody(16093.44, 600, "imperial"); got != "10.0 mi, 10 min" {
		t.Fatal(got)
	}
	if got := driveBody(16000, 600, "metric"); got != "16.0 km, 10 min" {
		t.Fatal(got)
	}
	if got := formatDistanceWhole(16093.44, "metric"); got != "16 km" {
		t.Fatal(got)
	}
	// Unknown/empty falls back to miles (the app default).
	if got := formatDistance(1609.344, ""); got != "1.0 mi" {
		t.Fatal(got)
	}
}

func TestWeeklyPushTextMetric(t *testing.T) {
	ms := []weekMember{{Name: "Alex", Current: weekStat{Drives: 2, DistanceM: 100_000}}}
	_, body, _ := weeklyPushText(ms, func(n string) string { return n }, "metric")
	if body != "Your family's week: 2 drives, 100 km" {
		t.Fatal(body)
	}
}

func TestShowNamesAndUnitsPerRecipient(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	if err := fx.srv.EnsureNotificationSchema(ctx); err != nil {
		t.Fatal(err)
	}
	if err := fx.srv.EnsureThemeSchema(ctx); err != nil {
		t.Fatal(err)
	}
	r := chi.NewRouter()
	r.Get("/me/notifications", fx.srv.GetNotificationPrefs)
	r.Put("/me/notifications", fx.srv.PutNotificationPrefs)

	// Defaults: names off, units unset.
	code, got := callJSON(t, r, "GET", "/me/notifications", fx.b, nil)
	if code != 200 || got["show_names"] != false || got["units"] != "" {
		t.Fatalf("defaults %d %v", code, got)
	}
	if code, _ := callJSON(t, r, "PUT", "/me/notifications", fx.b, map[string]any{"units": "furlongs"}); code != 400 {
		t.Fatalf("bad units accepted: %d", code)
	}
	// Add a second recipient device.
	if _, err := fx.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/c')`, fx.c); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = fx.pool.Exec(ctx, `DELETE FROM notification_prefs WHERE user_id IN ($1,$2)`, fx.b, fx.c) })

	// b opts in to names and metric; c stays default.
	if code, _ := callJSON(t, r, "PUT", "/me/notifications", fx.b, map[string]any{"show_names": true, "units": "metric"}); code != 200 {
		t.Fatalf("put %d", code)
	}
	if code, got := callJSON(t, r, "GET", "/me/notifications", fx.b, nil); code != 200 || got["show_names"] != true || got["units"] != "metric" || got["place_alerts"] != true {
		t.Fatalf("after put %d %v", code, got)
	}

	// Check-in with a note: b sees the name and note, c sees neither.
	a := fx.newSOS(t)
	a.Type, a.Note = alertCheckIn, "at the park"
	fx.srv.fanOutAlert(a, false)
	byEndpoint := map[string]string{}
	fx.push.mu.Lock()
	for _, n := range fx.push.sent {
		byEndpoint[n.UnifiedPushEndpoint] = n.Title + " | " + n.Body
	}
	fx.push.mu.Unlock()
	if !strings.Contains(byEndpoint["https://ntfy.example/b"], "A checked in") || !strings.Contains(byEndpoint["https://ntfy.example/b"], "at the park") {
		t.Fatalf("opted-in recipient: %q", byEndpoint["https://ntfy.example/b"])
	}
	if v := byEndpoint["https://ntfy.example/c"]; v == "" || strings.Contains(v, "A checked") || strings.Contains(v, "park") || !strings.Contains(v, "A family member") {
		t.Fatalf("default recipient leaks or missing: %q", v)
	}

	// Per-recipient units.
	dir := fx.srv.recipients(ctx)
	if dir.For(fx.b).Units != "metric" || !dir.For(fx.b).Show {
		t.Fatalf("b: %+v", dir.For(fx.b))
	}
	if c := dir.For(fx.c); c.Units != "imperial" || c.Show {
		t.Fatalf("c: %+v", c)
	}
	// Instance default applies to people who have not chosen.
	if _, err := fx.pool.Exec(ctx, `UPDATE app_theme_settings SET default_units = 'metric' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = fx.pool.Exec(ctx, `UPDATE app_theme_settings SET default_units = 'imperial' WHERE id = 1`) })
	if fx.srv.recipients(ctx).For(fx.c).Units != "metric" {
		t.Fatal("instance default not applied")
	}
	// VERBOSE_PUSH shows names to everyone.
	fx.srv.VerbosePush = true
	if !fx.srv.recipients(ctx).For(fx.c).Show {
		t.Fatal("verbose should show")
	}
}
