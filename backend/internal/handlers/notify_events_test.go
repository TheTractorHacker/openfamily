package handlers

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestBatteryTrackerCrossesOncePerDrop(t *testing.T) {
	tr := &batteryTracker{below: map[string]bool{}}
	steps := []struct {
		pct  float64
		want bool
	}{
		{50, false}, {25, false}, {19, true}, {18, false}, {12, false},
		{25, false}, // still under the reset line: not re-armed
		{35, false}, // re-armed
		{19.5, true}, {31, false}, {5, true},
	}
	for i, st := range steps {
		if got := tr.crossed("u1", st.pct); got != st.want {
			t.Fatalf("step %d (%.1f%%): got %v, want %v", i, st.pct, got, st.want)
		}
	}
	if !tr.crossed("u2", 10) { // other people are independent
		t.Fatal("u2 should be announced independently")
	}
}

func TestDriveBody(t *testing.T) {
	if got, want := driveBody(8690, 14*60, "imperial"), "5.4 mi, 14 min"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

const nwsFixture = `{"features":[
 {"properties":{"id":"urn:a","event":"Tornado Warning","severity":"Extreme","headline":"Tornado Warning issued","status":"Actual","messageType":"Alert","expires":"2026-11-01T20:00:00-05:00"}},
 {"properties":{"id":"urn:b","event":"Flood Advisory","severity":"Minor","headline":"minor","status":"Actual","messageType":"Alert"}},
 {"properties":{"id":"urn:c","event":"Severe Thunderstorm Warning","severity":"Severe","headline":"test","status":"Test","messageType":"Alert"}},
 {"properties":{"id":"urn:d","event":"Winter Storm Warning","severity":"Severe","headline":"cancel","status":"Actual","messageType":"Cancel"}},
 {"properties":{"id":"urn:e","event":"Severe Thunderstorm Warning","severity":"Severe","headline":"Storm headline","status":"Actual","messageType":"Update"}}
]}`

func TestParseSevereAlerts(t *testing.T) {
	got, err := parseSevereAlerts([]byte(nwsFixture))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != "urn:a" || got[1].ID != "urn:e" {
		t.Fatalf("unexpected alerts: %+v", got)
	}
	if got[0].Expires.IsZero() {
		t.Fatal("expires not parsed")
	}
	if _, err := parseSevereAlerts([]byte("not json")); err == nil {
		t.Fatal("want error on bad json")
	}
}

func TestWeatherCellRounds(t *testing.T) {
	k, la, lo := weatherCell(35.64912, -94.25484)
	if k != "35.6,-94.3" || la != 35.6 || lo != -94.3 {
		t.Fatalf("got %s %v %v", k, la, lo)
	}
}

func TestWeatherWorkerDedupesAndSendsOnlyToCellUsers(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		if r.Header.Get("User-Agent") == "" {
			t.Error("missing User-Agent")
		}
		if r.URL.Query().Get("point") != "35.6,-94.3" {
			w.WriteHeader(http.StatusNotFound) // outside the test cell
			return
		}
		fmt.Fprint(w, nwsFixture)
	}))
	defer srv.Close()

	type sent struct{ user, title, body string }
	var log []sent
	w := newWeatherWorker(func(_ context.Context, u weatherUser, title, body string) bool {
		log = append(log, sent{u.id, title, body})
		return true
	})
	w.baseURL, w.pause = srv.URL, 0

	cells := map[string][]weatherUser{
		"35.6,-94.3": {{id: "a", family: "f"}, {id: "b", family: "f"}},
		"40.0,-80.0": {{id: "c", family: "g"}}, // 404 from the fake: nothing sent
	}
	now := time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)
	if n := w.run(context.Background(), cells, now); n != 4 { // 2 alerts x 2 users
		t.Fatalf("first pass pushed %d, want 4", n)
	}
	if n := w.run(context.Background(), cells, now.Add(15*time.Minute)); n != 0 {
		t.Fatalf("second pass pushed %d, want 0 (deduped)", n)
	}
	for _, s := range log {
		if s.user == "c" {
			t.Fatal("user outside the alert area was notified")
		}
		if s.title == "" || s.body == "" {
			t.Fatalf("empty push: %+v", s)
		}
	}
	if atomic.LoadInt32(&hits) < 3 {
		t.Fatalf("expected lookups for both cells on both passes, got %d", hits)
	}
}
