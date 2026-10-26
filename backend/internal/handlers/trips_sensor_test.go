package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

func f64(v float64) *float64 { return &v }

func TestValidateSensorEvent(t *testing.T) {
	now := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	ts := func(d time.Duration) string { return now.Add(d).Format(time.RFC3339) }
	ok := sensorEventIn{Kind: "hard_brake", StartedAt: ts(-time.Minute), EndedAt: ts(-time.Minute + 2*time.Second), Magnitude: f64(5)}
	if _, good := validateSensorEvent(ok, now); !good {
		t.Fatal("valid event rejected")
	}
	mod := func(f func(e *sensorEventIn)) sensorEventIn { e := ok; f(&e); return e }
	bad := map[string]sensorEventIn{
		"kind":            mod(func(e *sensorEventIn) { e.Kind = "speeding" }),
		"empty kind":      mod(func(e *sensorEventIn) { e.Kind = "" }),
		"start format":    mod(func(e *sensorEventIn) { e.StartedAt = "yesterday" }),
		"too old":         mod(func(e *sensorEventIn) { e.StartedAt = ts(-7*24*time.Hour - time.Minute); e.EndedAt = e.StartedAt }),
		"future":          mod(func(e *sensorEventIn) { e.StartedAt = ts(6 * time.Minute); e.EndedAt = e.StartedAt }),
		"end before":      mod(func(e *sensorEventIn) { e.EndedAt = ts(-2 * time.Minute) }),
		"too long":        mod(func(e *sensorEventIn) { e.EndedAt = ts(-time.Minute + 5*time.Minute + time.Second) }),
		"no magnitude":    mod(func(e *sensorEventIn) { e.Magnitude = nil }),
		"negative":        mod(func(e *sensorEventIn) { e.Magnitude = f64(-0.1) }),
		"accel too big":   mod(func(e *sensorEventIn) { e.Magnitude = f64(30.5) }),
		"phone too big":   mod(func(e *sensorEventIn) { e.Kind = "phone_use"; e.Magnitude = f64(301) }),
		"lat only":        mod(func(e *sensorEventIn) { e.Lat = f64(10) }),
		"lat range":       mod(func(e *sensorEventIn) { e.Lat, e.Lon = f64(91), f64(0) }),
		"lon range":       mod(func(e *sensorEventIn) { e.Lat, e.Lon = f64(0), f64(-180.5) }),
	}
	for name, e := range bad {
		if _, good := validateSensorEvent(e, now); good {
			t.Errorf("%s accepted", name)
		}
	}
	good := map[string]sensorEventIn{
		"phone 300":   mod(func(e *sensorEventIn) { e.Kind = "phone_use"; e.Magnitude = f64(300) }),
		"accel 30":    mod(func(e *sensorEventIn) { e.Magnitude = f64(30) }),
		"skew":        mod(func(e *sensorEventIn) { e.StartedAt = ts(4 * time.Minute); e.EndedAt = ts(4 * time.Minute) }),
		"5 min exact": mod(func(e *sensorEventIn) { e.EndedAt = ts(-time.Minute + 5*time.Minute) }),
		"with fix":    mod(func(e *sensorEventIn) { e.Lat, e.Lon = f64(-90), f64(180) }),
	}
	for name, e := range good {
		if _, g := validateSensorEvent(e, now); !g {
			t.Errorf("%s rejected", name)
		}
	}
}

func TestSensorEventsUnauthenticated(t *testing.T) {
	w := httptest.NewRecorder()
	(&Server{}).IngestSensorEvents(w, httptest.NewRequest("POST", "/trips/sensor-events", strings.NewReader(`{}`)))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("%d", w.Code)
	}
}

// sensorEnv wraps the shared trip fixtures with the real ingest middleware.
type sensorEnv struct {
	*tripEnv
	tm     *auth.TokenManager
	router http.Handler
}

func setupSensorEnv(t *testing.T) *sensorEnv {
	e := setupTripEnv(t)
	tm := auth.NewTokenManager("test-secret-at-least-32-bytes-long!", time.Minute, time.Hour)
	r := chi.NewRouter()
	r.Use(middleware.RequireAuthOrDeviceIngestKey(tm, e.pool))
	r.Post("/trips/sensor-events", e.srv.IngestSensorEvents)
	return &sensorEnv{tripEnv: e, tm: tm, router: r}
}

// device creates a device with an ingest key for the user.
func (e *sensorEnv) device(userID string) (id, header string) {
	key, err := middleware.GenerateDeviceIngestKey()
	e.must(err)
	hash := middleware.EncodeIngestKeyHash(middleware.HashDeviceIngestKey(key))
	e.must(e.pool.QueryRow(context.Background(),
		`INSERT INTO devices (user_id, platform, ingest_key_hash) VALUES ($1,'android',$2) RETURNING id::text`, userID, hash).Scan(&id))
	return id, id + "." + key
}

func (e *sensorEnv) post(headers map[string]string, body string) (int, map[string]any) {
	req := httptest.NewRequest("POST", "/trips/sensor-events", strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	e.router.ServeHTTP(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func (e *sensorEnv) bearer(userID string) map[string]string {
	var v int
	e.must(e.pool.QueryRow(context.Background(), `SELECT token_version FROM users WHERE id=$1`, userID).Scan(&v))
	tok, err := e.tm.IssueAccess(userID, "", v)
	e.must(err)
	return map[string]string{"Authorization": "Bearer " + tok}
}

func evJSON(kind string, at time.Time, dur time.Duration, mag float64) string {
	return fmt.Sprintf(`{"kind":%q,"started_at":%q,"ended_at":%q,"magnitude":%v,"lat":40.1,"lon":-75.2}`,
		kind, at.UTC().Format(time.RFC3339), at.Add(dur).UTC().Format(time.RFC3339), mag)
}

func evBody(enabled string, evs ...string) string {
	s := `{"events":[` + strings.Join(evs, ",") + `]`
	if enabled != "" {
		s += `,"sensor_enabled":` + enabled
	}
	return s + `}`
}

func num(m map[string]any, k string) int { f, _ := m[k].(float64); return int(f) }

func (e *sensorEnv) countEvents(userID, where string) int {
	var n int
	e.must(e.pool.QueryRow(context.Background(), `SELECT count(*) FROM trip_events WHERE user_id=$1 AND `+where, userID).Scan(&n))
	return n
}

func TestSensorAuth(t *testing.T) {
	e := setupSensorEnv(t)
	at := time.Now().Add(-time.Minute)
	body := evBody("true", evJSON("hard_brake", at, time.Second, 4))

	if code, _ := e.post(nil, body); code != 401 {
		t.Errorf("no credentials: %d", code)
	}
	devA, hdrA := e.device(e.a1)
	devB, hdrB := e.device(e.b1)
	_ = devB
	if code, _ := e.post(map[string]string{"X-Device-Key": "garbage"}, body); code != 401 {
		t.Errorf("malformed key: %d", code)
	}
	// Key of device A presented for device B's id: wrong key for that device.
	wrong := devB + "." + strings.SplitN(hdrA, ".", 2)[1]
	if code, _ := e.post(map[string]string{"X-Device-Key": wrong}, body); code != 401 {
		t.Errorf("wrong device: %d", code)
	}
	// Body naming another device is rejected by the key binding.
	other := strings.Replace(body, `{"events"`, `{"device_id":"`+devB+`","events"`, 1)
	if code, _ := e.post(map[string]string{"X-Device-Key": hdrA}, other); code != 403 {
		t.Errorf("body device mismatch: %d", code)
	}
	code, out := e.post(map[string]string{"X-Device-Key": hdrA}, body)
	if code != 200 || num(out, "accepted") != 1 {
		t.Fatalf("valid key: %d %v", code, out)
	}
	var dev, uid string
	e.must(e.pool.QueryRow(context.Background(), `SELECT device_id::text, user_id::text FROM trip_events WHERE user_id=$1 AND source='sensor'`, e.a1).Scan(&dev, &uid))
	if dev != devA {
		t.Errorf("stored device %s want %s", dev, devA)
	}
	// Events are attributed to the key's user, never another one.
	if e.countEvents(e.b1, "true") != 0 {
		t.Error("leaked to another user")
	}
	// Revoked key.
	_, err := e.pool.Exec(context.Background(), `UPDATE devices SET ingest_key_hash=NULL WHERE id=$1`, devA)
	e.must(err)
	if code, _ := e.post(map[string]string{"X-Device-Key": hdrA}, body); code != 401 {
		t.Errorf("revoked key: %d", code)
	}
	// Expired key.
	_, err = e.pool.Exec(context.Background(), `UPDATE devices SET ingest_key_hash=$2, ingest_key_expires_at=now()-interval '1 hour' WHERE id=$1`,
		devB, middleware.EncodeIngestKeyHash(middleware.HashDeviceIngestKey(strings.SplitN(hdrB, ".", 2)[1])))
	e.must(err)
	if code, _ := e.post(map[string]string{"X-Device-Key": hdrB}, body); code != 401 {
		t.Errorf("expired key: %d", code)
	}
	// Access token works too, with no device recorded.
	code, out = e.post(e.bearer(e.a2), evBody("true", evJSON("rapid_accel", at, time.Second, 4)))
	if code != 200 || num(out, "accepted") != 1 {
		t.Fatalf("bearer: %d %v", code, out)
	}
	var n int
	e.must(e.pool.QueryRow(context.Background(), `SELECT count(*) FROM trip_events WHERE user_id=$1 AND device_id IS NULL`, e.a2).Scan(&n))
	if n != 1 {
		t.Errorf("bearer event device not null")
	}
}

func TestSensorLimitsAndValidation(t *testing.T) {
	e := setupSensorEnv(t)
	h := e.bearer(e.a1)
	at := time.Now().Add(-time.Hour)

	// More than 100 events: whole request refused.
	evs := make([]string, 101)
	for i := range evs {
		evs[i] = evJSON("hard_brake", at.Add(-time.Duration(i)*time.Minute), time.Second, 4)
	}
	if code, _ := e.post(h, evBody("true", evs...)); code != 400 {
		t.Errorf("101 events: %d", code)
	}
	// Exactly 100 accepted.
	code, out := e.post(h, evBody("true", evs[:100]...))
	if code != 200 || num(out, "accepted") != 100 {
		t.Errorf("100 events: %d %v", code, out)
	}
	// Body over 64 KB.
	big := strings.Repeat(" ", 70<<10) + evBody("true", evJSON("hard_brake", at, time.Second, 4))
	if code, _ := e.post(h, big); code != 413 {
		t.Errorf("big body: %d", code)
	}
	for name, body := range map[string]string{"empty": `{}`, "not json": `nope`, "no events": `{"events":[]}`} {
		if code, _ := e.post(h, body); code != 400 {
			t.Errorf("%s: %d", name, code)
		}
	}
	// Mixed valid / invalid counts.
	code, out = e.post(h, evBody("", evJSON("rapid_accel", at.Add(-time.Hour), time.Second, 3),
		evJSON("hard_brake", at.Add(-2*time.Hour), time.Second, 99),
		`{"kind":"nope","started_at":"x","ended_at":"y","magnitude":1}`))
	if code != 200 || num(out, "accepted") != 1 || num(out, "rejected") != 2 || num(out, "duplicate") != 0 {
		t.Errorf("mixed: %d %v", code, out)
	}
	// Null location is fine.
	code, out = e.post(h, evBody("", `{"kind":"phone_use","started_at":"`+at.Add(-3*time.Hour).UTC().Format(time.RFC3339)+`","ended_at":"`+at.Add(-3*time.Hour+30*time.Second).UTC().Format(time.RFC3339)+`","magnitude":30,"lat":null,"lon":null}`))
	if code != 200 || num(out, "accepted") != 1 {
		t.Errorf("null location: %d %v", code, out)
	}
}

func TestSensorRateLimit(t *testing.T) {
	e := setupSensorEnv(t)
	e.srv.LocationLimit = sms.NewLimiter()
	h := e.bearer(e.a1)
	body := evBody("true")
	got429 := false
	for i := 0; i < sensorRateLimit+2; i++ {
		code, _ := e.post(h, body)
		if code == 429 {
			got429 = true
			if i != sensorRateLimit {
				t.Errorf("limited at request %d", i)
			}
			break
		}
	}
	if !got429 {
		t.Error("never rate limited")
	}
	// Another device/user is unaffected.
	if code, _ := e.post(e.bearer(e.a2), body); code != 200 {
		t.Errorf("other user: %d", code)
	}
}

func TestSensorIdempotentAndIsolation(t *testing.T) {
	e := setupSensorEnv(t)
	at := time.Now().Add(-30 * time.Minute)
	body := evBody("true", evJSON("hard_brake", at, time.Second, 4), evJSON("hard_brake", at, time.Second, 4), evJSON("rapid_accel", at, time.Second, 4))
	code, out := e.post(e.bearer(e.a1), body)
	if code != 200 || num(out, "accepted") != 2 || num(out, "duplicate") != 1 {
		t.Fatalf("first: %d %v", code, out)
	}
	code, out = e.post(e.bearer(e.a1), body)
	if code != 200 || num(out, "accepted") != 0 || num(out, "duplicate") != 3 {
		t.Fatalf("retry: %d %v", code, out)
	}
	if n := e.countEvents(e.a1, "source='sensor'"); n != 2 {
		t.Errorf("stored %d", n)
	}
	// The same event from another user is independent.
	code, out = e.post(e.bearer(e.b1), body)
	if code != 200 || num(out, "accepted") != 2 {
		t.Fatalf("other user: %d %v", code, out)
	}
	if e.countEvents(e.a1, "source='sensor'") != 2 || e.countEvents(e.b1, "source='sensor'") != 2 {
		t.Error("cross-user interference")
	}
}

func (e *sensorEnv) tripOf(userID string) (id string, start, end time.Time) {
	e.must(e.pool.QueryRow(context.Background(), `SELECT id::text, started_at, ended_at FROM trips WHERE user_id=$1 ORDER BY started_at LIMIT 1`, userID).Scan(&id, &start, &end))
	return
}

func TestSensorLinking(t *testing.T) {
	e := setupSensorEnv(t)
	ctx := context.Background()
	st := trips.NewStore(e.pool)

	// Trip exists first: the event attaches at ingest.
	e.must2(st.ProcessUser(ctx, e.a1, e.famA))
	tid, ts, _ := e.tripOf(e.a1)
	inside := ts.Add(2 * time.Minute)
	outside := ts.Add(-30 * time.Minute)
	code, out := e.post(e.bearer(e.a1), evBody("true", evJSON("hard_brake", inside, time.Second, 4), evJSON("hard_brake", outside, time.Second, 4)))
	if code != 200 || num(out, "accepted") != 2 {
		t.Fatalf("%d %v", code, out)
	}
	if e.countEvents(e.a1, "source='sensor' AND trip_id='"+tid+"'") != 1 || e.countEvents(e.a1, "source='sensor' AND trip_id IS NULL") != 1 {
		t.Fatal("ingest linking wrong")
	}

	// Event first, trip computed later (a fresh user with a drive).
	u := e.user("late", e.famA)
	t.Cleanup(func() { e.pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, u) })
	e.drive(u, 0.3)
	at := e.driveStart.Add(3 * time.Minute)
	code, out = e.post(e.bearer(u), evBody("true", evJSON("rapid_accel", at, time.Second, 4)))
	if code != 200 || num(out, "accepted") != 1 {
		t.Fatalf("%d %v", code, out)
	}
	if e.countEvents(u, "trip_id IS NULL") != 1 {
		t.Fatal("expected unattached event")
	}
	e.must2(st.ProcessUser(ctx, u, e.famA))
	tid2, _, _ := e.tripOf(u)
	if e.countEvents(u, "source='sensor' AND trip_id='"+tid2+"'") != 1 {
		t.Fatal("event not linked when trip created later")
	}

	// Recompute keeps sensor events (new trip id) and still links them; GPS
	// rows are replaced.
	_, err := e.pool.Exec(ctx, `INSERT INTO trip_events (trip_id,user_id,kind,started_at,ended_at,magnitude,lat,lon) VALUES ($1,$2,'speeding',$3,$3,30,40,-75)`, tid2, u, at)
	e.must(err)
	_, ts2, te2 := e.tripOf(u)
	n, err := st.ComputeRange(ctx, u, e.famA, ts2.Add(-time.Hour), te2.Add(time.Hour))
	e.must(err)
	if n != 1 {
		t.Fatalf("recomputed %d", n)
	}
	tid3, _, _ := e.tripOf(u)
	if tid3 == tid2 {
		t.Log("trip id unchanged")
	}
	if e.countEvents(u, "source='sensor' AND trip_id='"+tid3+"'") != 1 {
		t.Error("sensor event lost or unlinked after recompute")
	}
	if e.countEvents(u, "source='gps'") != 0 {
		t.Error("stale gps event survived recompute")
	}
	// Reprocessing is idempotent for sensor events.
	e.must2(st.ProcessUser(ctx, u, e.famA))
	if e.countEvents(u, "source='sensor'") != 1 {
		t.Error("sensor events changed by ProcessUser")
	}
}

func (e *tripEnv) must2(_ int, err error) { e.t.Helper(); e.must(err) }

func (e *sensorEnv) reportJSON(as, circle string) map[string]any {
	code, _, raw := e.report(as, "?period=month&circle_id="+circle)
	if code != 200 {
		e.t.Fatalf("report %d %s", code, raw)
	}
	var m map[string]any
	e.must(json.Unmarshal([]byte(raw), &m))
	return m
}

func memberEvents(m map[string]any, uid string) map[string]any {
	for _, x := range m["members"].([]any) {
		mm := x.(map[string]any)
		if mm["user_id"] == uid {
			return mm["events"].(map[string]any)
		}
	}
	return nil
}

func TestSensorWinsReportAndPhoneUse(t *testing.T) {
	e := setupSensorEnv(t)
	ctx := context.Background()
	st := trips.NewStore(e.pool)
	e.must2(st.ProcessUser(ctx, e.a1, e.famA))
	tid, ts, _ := e.tripOf(e.a1)
	gps := func(kind string, at time.Time) {
		_, err := e.pool.Exec(ctx, `INSERT INTO trip_events (trip_id,user_id,kind,started_at,ended_at,magnitude,lat,lon) VALUES ($1,$2,$3,$4,$4,4,40,-75)`, tid, e.a1, kind, at)
		e.must(err)
	}
	base := ts.Add(30 * time.Second)
	gps("hard_brake", base)                       // within 4 s of a sensor event: hidden
	gps("hard_brake", base.Add(time.Minute))      // no sensor neighbour: counted
	gps("rapid_accel", base)                      // other kind: counted
	gps("hard_brake", base.Add(4*time.Minute))   // 7 s away from sensor event: counted
	sensorAt := base.Add(3 * time.Second)
	farAt := base.Add(4*time.Minute + 7*time.Second) // > 4 s after the gps end
	// Before opt-in the report has the gps counts and phone_use null.
	r := e.reportJSON(e.a2, e.famA)
	ev := memberEvents(r, e.a1)
	if ev["hard_brake"].(float64) != 3 || ev["phone_use"] != nil {
		t.Fatalf("pre-sensor %v", ev)
	}
	if sm := r["sensor_members"].([]any); len(sm) != 0 {
		t.Fatalf("sensor_members %v", sm)
	}
	if r["totals"].(map[string]any)["events"].(map[string]any)["phone_use"] != nil {
		t.Fatal("totals phone_use should be null")
	}

	code, out := e.post(e.bearer(e.a1), evBody("true",
		evJSON("hard_brake", sensorAt, time.Second, 6),
		evJSON("hard_brake", farAt, time.Second, 6),
		evJSON("phone_use", base, 20*time.Second, 20),
		evJSON("phone_use", base.Add(time.Hour), 20*time.Second, 20)))
	if code != 200 || num(out, "accepted") != 4 {
		t.Fatalf("%d %v", code, out)
	}
	r = e.reportJSON(e.a2, e.famA)
	ev = memberEvents(r, e.a1)
	// gps: base(hidden), base+1m, base+10m(hidden: sensor at +10m7s is within 4s of its end? start diff 7s > 4 => visible)
	// sensor: sensorAt, farAt  => visible gps 2 + sensor 2 = 4
	if ev["hard_brake"].(float64) != 4 || ev["rapid_accel"].(float64) != 1 || ev["phone_use"].(float64) != 2 {
		t.Fatalf("merged %v", ev)
	}
	if sm := r["sensor_members"].([]any); len(sm) != 1 || sm[0] != e.a1 {
		t.Fatalf("sensor_members %v", r["sensor_members"])
	}
	// a2 never opted in: null even though members list includes them.
	if memberEvents(r, e.a2)["phone_use"] != nil {
		t.Error("a2 phone_use should be null")
	}
	tot := r["totals"].(map[string]any)["events"].(map[string]any)
	if tot["phone_use"].(float64) != 2 || tot["hard_brake"].(float64) != 4 {
		t.Errorf("totals %v", tot)
	}
	// GPS rows stay stored.
	if e.countEvents(e.a1, "source='gps' AND kind='hard_brake'") != 3 {
		t.Error("gps rows were removed")
	}

	// Trip events list: source is present, hidden gps row is absent.
	w := httptest.NewRecorder()
	reportRouter(e.srv, e.a2).ServeHTTP(w, httptest.NewRequest("GET", "/trips/"+tid+"/events", nil))
	var er struct {
		Events []trips.EventRow `json:"events"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &er)
	bySrc := map[string]int{}
	for _, x := range er.Events {
		bySrc[x.Source+"/"+x.Kind]++
	}
	if w.Code != 200 || bySrc["sensor/hard_brake"] != 2 || bySrc["gps/hard_brake"] != 2 || bySrc["gps/rapid_accel"] != 1 || bySrc["sensor/phone_use"] != 1 {
		t.Fatalf("events %d %v %s", w.Code, bySrc, w.Body.String())
	}

	// Opt-out: events stop being accepted, existing ones stay, phone_use is null again.
	code, out = e.post(e.bearer(e.a1), evBody("false", evJSON("hard_brake", base.Add(2*time.Hour), time.Second, 6)))
	if code != 200 || num(out, "accepted") != 0 || num(out, "rejected") != 1 || out["sensor_enabled"] != false {
		t.Fatalf("opt-out %d %v", code, out)
	}
	code, out = e.post(e.bearer(e.a1), evBody("", evJSON("hard_brake", base.Add(2*time.Hour), time.Second, 6)))
	if code != 200 || num(out, "accepted") != 0 {
		t.Fatalf("after opt-out %d %v", code, out)
	}
	if e.countEvents(e.a1, "source='sensor'") != 4 {
		t.Error("existing sensor events removed on opt-out")
	}
	r = e.reportJSON(e.a2, e.famA)
	if memberEvents(r, e.a1)["phone_use"] != nil || len(r["sensor_members"].([]any)) != 0 {
		t.Error("phone_use not hidden after opt-out")
	}
	if memberEvents(r, e.a1)["hard_brake"].(float64) != 4 {
		t.Error("braking counts should still include stored sensor events")
	}
	// A toggle-only request works.
	if code, out = e.post(e.bearer(e.a1), `{"sensor_enabled":true}`); code != 200 || out["sensor_enabled"] != true {
		t.Errorf("toggle %d %v", code, out)
	}

	// Isolation: the other family sees neither the report member nor the events.
	if code, _, _ := e.report(e.b1, "?circle_id="+e.famA); code != http.StatusNotFound {
		t.Errorf("b1 report: %d", code)
	}
	w = httptest.NewRecorder()
	reportRouter(e.srv, e.b1).ServeHTTP(w, httptest.NewRequest("GET", "/trips/"+tid+"/events", nil))
	if w.Code != http.StatusNotFound {
		t.Errorf("b1 events: %d", w.Code)
	}
	// b1's own report has no a1 data and phone_use null.
	own := e.reportJSON(e.b1, e.famB)
	if memberEvents(own, e.b1)["phone_use"] != nil {
		t.Error("b1 phone_use")
	}
}

func TestSensorExportDeletionAndRetention(t *testing.T) {
	e := setupSensorEnv(t)
	ctx := context.Background()
	at := time.Now().Add(-time.Hour)
	if code, out := e.post(e.bearer(e.a1), evBody("true", evJSON("hard_brake", at, time.Second, 4))); code != 200 || num(out, "accepted") != 1 {
		t.Fatalf("%d %v", code, out)
	}
	if code, out := e.post(e.bearer(e.b1), evBody("true", evJSON("hard_brake", at, time.Second, 4))); code != 200 || num(out, "accepted") != 1 {
		t.Fatalf("%d %v", code, out)
	}

	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: e.a1}))
			next.ServeHTTP(w, req)
		})
	})
	r.Get("/me/export", e.srv.ExportMe)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/me/export", nil))
	var exp struct {
		Enabled bool `json:"driving_sensor_enabled"`
		Events  []struct {
			Source string `json:"source"`
			Kind   string `json:"kind"`
		} `json:"driving_events"`
		Complete bool `json:"complete"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(w.Body.Bytes()), &exp); err != nil || w.Code != 200 {
		t.Fatalf("export %d %v %s", w.Code, err, w.Body.String())
	}
	if !exp.Complete || !exp.Enabled || len(exp.Events) != 1 || exp.Events[0].Source != "sensor" {
		t.Fatalf("export %+v", exp)
	}

	// Retention: old events (attached or not) are purged by the trips worker.
	old := time.Now().AddDate(0, 0, -400)
	_, err := e.pool.Exec(ctx, `INSERT INTO trip_events (user_id, source, kind, started_at, ended_at, magnitude) VALUES ($1,'sensor','hard_brake',$2,$2,3)`, e.a1, old)
	e.must(err)
	(&trips.Worker{Store: trips.NewStore(e.pool)}).Pass(ctx)
	if e.countEvents(e.a1, "started_at < now() - interval '300 days'") != 0 {
		t.Error("old sensor event not purged")
	}
	if e.countEvents(e.a1, "source='sensor'") != 1 {
		t.Error("recent sensor event purged")
	}

	// Account deletion cascades to events (users FK); device deletion keeps them.
	devID, _ := e.device(e.a1)
	_, err = e.pool.Exec(ctx, `UPDATE trip_events SET device_id=$2 WHERE user_id=$1`, e.a1, devID)
	e.must(err)
	_, err = e.pool.Exec(ctx, `DELETE FROM devices WHERE id=$1`, devID)
	e.must(err)
	if e.countEvents(e.a1, "source='sensor' AND device_id IS NULL") != 1 {
		t.Error("device deletion should keep events")
	}
	_, err = e.pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, e.a1)
	e.must(err)
	if e.countEvents(e.a1, "true") != 0 {
		t.Error("events survived account deletion")
	}
	if e.countEvents(e.b1, "source='sensor'") != 1 {
		t.Error("other user's events were affected")
	}
}
