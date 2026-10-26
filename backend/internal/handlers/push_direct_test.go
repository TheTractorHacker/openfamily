package handlers

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

func TestValidatePushTransport(t *testing.T) {
	on := &Server{Direct: &push.DirectBroker{}}
	off := &Server{}
	cases := []struct {
		name      string
		s         *Server
		platform  string
		transport string
		wantErr   bool
	}{
		{"empty ok", on, "ios", "", false},
		{"android direct", on, "android", "direct", false},
		{"ios direct refused", on, "ios", "direct", true},
		{"web direct refused", on, "web", "direct", true},
		{"disabled server refuses", off, "android", "direct", true},
		{"unknown value", on, "android", "carrier-pigeon", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.s.validatePushTransport(tc.platform, tc.transport) != ""; got != tc.wantErr {
				t.Fatalf("error = %v, want %v", got, tc.wantErr)
			}
		})
	}
}

// directFixture wires the real dispatcher + broker + auth middleware over the
// shared alert fixture, behind an httptest server.
type directFixture struct {
	*alertFixture
	ts     *httptest.Server
	broker *push.DirectBroker
	dev    string // B's direct device
	key    string
}

func newDirectFixture(t *testing.T) *directFixture {
	t.Helper()
	// Registered first so it runs last: handlers read these until ts.Close.
	oldHB, oldRV := pushHeartbeatInterval, pushRevalidateInterval
	pushHeartbeatInterval, pushRevalidateInterval = 100*time.Millisecond, 50*time.Millisecond
	t.Cleanup(func() { pushHeartbeatInterval, pushRevalidateInterval = oldHB, oldRV })

	fx := newAlertFixture(t)
	ctx := context.Background()
	// B's existing UnifiedPush device becomes a direct-only device.
	if _, err := fx.pool.Exec(ctx, `DELETE FROM devices WHERE user_id = $1`, fx.b); err != nil {
		t.Fatal(err)
	}
	key, _ := middleware.GenerateDeviceIngestKey()
	d := &directFixture{alertFixture: fx, key: key}
	if err := fx.pool.QueryRow(ctx, `
		INSERT INTO devices (user_id, platform, push_transport, ingest_key_hash)
		VALUES ($1,'android','direct',$2) RETURNING id`,
		fx.b, middleware.EncodeIngestKeyHash(middleware.HashDeviceIngestKey(key))).Scan(&d.dev); err != nil {
		t.Fatal(err)
	}
	d.broker = push.NewDirectBroker(fx.pool)
	disp := push.NewDispatcher(push.APNsConfig{})
	disp.SetDirect(d.broker)
	fx.srv.Push = disp
	fx.srv.Direct = d.broker
	fx.srv.hub = newHub()

	r := chi.NewRouter()
	r.Group(func(r chi.Router) {
		r.Use(middleware.RequireAuthOrDeviceIngestKey(fx.srv.TM, fx.pool))
		r.Get("/push/stream", fx.srv.PushStream)
		r.Post("/push/ack", fx.srv.AckPush)
	})
	d.ts = httptest.NewServer(r)
	t.Cleanup(d.ts.Close)

	return d
}

func (d *directFixture) keyHeader() string { return d.dev + "." + d.key }

type sseStream struct {
	resp   *http.Response
	frames chan string // raw frames ("event: x\ndata: y")
	cancel context.CancelFunc
}

func (d *directFixture) open(t *testing.T, mutate func(*http.Request)) *sseStream {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, d.ts.URL+"/push/stream", nil)
	req.Header.Set(middleware.DeviceKeyHeader, d.keyHeader())
	if mutate != nil {
		mutate(req)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	s := &sseStream{resp: resp, frames: make(chan string, 64), cancel: cancel}
	if resp.StatusCode != http.StatusOK {
		close(s.frames)
		return s
	}
	go func() {
		defer close(s.frames)
		sc := bufio.NewScanner(resp.Body)
		var cur []string
		for sc.Scan() {
			line := sc.Text()
			if line == "" {
				if len(cur) > 0 {
					s.frames <- strings.Join(cur, "\n")
				}
				cur = nil
				continue
			}
			cur = append(cur, line)
		}
	}()
	t.Cleanup(func() { resp.Body.Close() })
	return s
}

// next returns the next frame containing want, or fails.
func (s *sseStream) waitFor(t *testing.T, want string) string {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case f, ok := <-s.frames:
			if !ok {
				t.Fatalf("stream closed while waiting for %q", want)
			}
			if strings.Contains(f, want) {
				return f
			}
		case <-deadline:
			t.Fatalf("timeout waiting for %q", want)
		}
	}
}

// closed waits for the stream to end.
func (s *sseStream) closed(t *testing.T) {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case _, ok := <-s.frames:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("stream was not closed")
		}
	}
}

func (d *directFixture) pushState(t *testing.T, alertID string) string {
	t.Helper()
	for _, dl := range d.deliveries(t, alertID) {
		if dl.Channel == "push" {
			return dl.State
		}
	}
	return "none"
}

func TestPushStreamAuthFailures(t *testing.T) {
	d := newDirectFixture(t)
	other := d.key[:len(d.key)-1] + "x"
	cases := []struct {
		name   string
		mutate func(*http.Request)
		want   int
	}{
		{"no credentials", func(r *http.Request) { r.Header.Del(middleware.DeviceKeyHeader) }, 401},
		{"wrong key", func(r *http.Request) { r.Header.Set(middleware.DeviceKeyHeader, d.dev+"."+other) }, 401},
		{"malformed key", func(r *http.Request) { r.Header.Set(middleware.DeviceKeyHeader, "garbage") }, 401},
		{"bad bearer", func(r *http.Request) {
			r.Header.Del(middleware.DeviceKeyHeader)
			r.Header.Set("Authorization", "Bearer nope")
		}, 401},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := d.open(t, tc.mutate).resp.StatusCode; got != tc.want {
				t.Fatalf("status = %d, want %d", got, tc.want)
			}
		})
	}

	bearer := func(uid string, ver int) string {
		tok, _ := d.srv.TM.IssueAccess(uid, d.f1, ver)
		return "Bearer " + tok
	}
	t.Run("bearer without device_id", func(t *testing.T) {
		s := d.open(t, func(r *http.Request) {
			r.Header.Del(middleware.DeviceKeyHeader)
			r.Header.Set("Authorization", bearer(d.b, 0))
		})
		if s.resp.StatusCode != 400 {
			t.Fatalf("status = %d, want 400", s.resp.StatusCode)
		}
	})
	t.Run("bearer for someone else's device", func(t *testing.T) {
		s := d.open(t, func(r *http.Request) {
			r.Header.Del(middleware.DeviceKeyHeader)
			r.Header.Set("Authorization", bearer(d.c, 0))
			r.URL.RawQuery = "device_id=" + d.dev
		})
		if s.resp.StatusCode != 404 {
			t.Fatalf("status = %d, want 404", s.resp.StatusCode)
		}
	})
	t.Run("bearer for own device works", func(t *testing.T) {
		s := d.open(t, func(r *http.Request) {
			r.Header.Del(middleware.DeviceKeyHeader)
			r.Header.Set("Authorization", bearer(d.b, 0))
			r.URL.RawQuery = "device_id=" + d.dev
		})
		if s.resp.StatusCode != 200 {
			t.Fatalf("status = %d, want 200", s.resp.StatusCode)
		}
		s.waitFor(t, "event: hello")
	})
}

var coordPattern = regexp.MustCompile(`-?\d+\.\d{3,}`)

func TestDirectAlertEndToEnd(t *testing.T) {
	d := newDirectFixture(t)
	al := d.newSOS(t)
	d.srv.fanOutAlert(al, false)

	// Queued before the device ever connects.
	if st := d.pushState(t, al.ID); st != "queued" {
		t.Fatalf("state before connect = %q, want queued", st)
	}

	s := d.open(t, nil)
	s.waitFor(t, "event: hello")
	f := s.waitFor(t, "event: push")
	var line string
	for _, l := range strings.Split(f, "\n") {
		if strings.HasPrefix(l, "data: ") {
			line = strings.TrimPrefix(l, "data: ")
		}
	}
	// Payload hygiene: no coordinates, no sender name (VERBOSE_PUSH is off).
	if coordPattern.MatchString(line) || strings.Contains(line, "A Tester") || strings.Contains(line, "51.5") {
		t.Fatalf("direct payload leaks: %s", line)
	}
	var p struct {
		ID, AlertID string
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		t.Fatal(err)
	}
	p.ID, _ = raw["id"].(string)
	p.AlertID, _ = raw["alert_id"].(string)
	if p.AlertID != al.ID || p.ID != "alert:"+al.ID || raw["kind"] != "alert" {
		t.Fatalf("payload = %v", raw)
	}
	for k := range raw {
		if k == "lat" || k == "lon" || k == "name" {
			t.Fatalf("forbidden key %q", k)
		}
	}
	// The state is recorded right after the frame is written.
	deadline := time.Now().Add(3 * time.Second)
	for d.pushState(t, al.ID) != "sent" && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if st := d.pushState(t, al.ID); st != "sent" {
		t.Fatalf("state after stream = %q, want sent", st)
	}

	// Ack (device received it): delivered.
	body := fmt.Sprintf(`{"ids":[%q]}`, p.ID)
	req, _ := http.NewRequest(http.MethodPost, d.ts.URL+"/push/ack", strings.NewReader(body))
	req.Header.Set(middleware.DeviceKeyHeader, d.keyHeader())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 204 {
		t.Fatalf("ack status = %d", resp.StatusCode)
	}
	if st := d.pushState(t, al.ID); st != "delivered" {
		t.Fatalf("state after ack = %q, want delivered", st)
	}
	// A late "sent" must never move delivered backwards.
	d.srv.recordDelivery(context.Background(), al.ID, d.b, "", "", chanPush, stSent, "")
	if st := d.pushState(t, al.ID); st != "delivered" {
		t.Fatalf("state regressed to %q", st)
	}

	// Reconnect: acked events are not re-sent.
	s.cancel()
	s2 := d.open(t, nil)
	s2.waitFor(t, "event: hello")
	select {
	case f := <-s2.frames:
		if strings.Contains(f, "event: push") {
			t.Fatalf("acked event redelivered: %s", f)
		}
	case <-time.After(300 * time.Millisecond):
	}

	// The person reading it in the app: acknowledged.
	if w := d.do(http.MethodPost, "/alerts/"+al.ID+"/ack", d.b); w.Code != 200 {
		t.Fatalf("alert ack = %d %s", w.Code, w.Body)
	}
	if st := d.pushState(t, al.ID); st != "acknowledged" {
		t.Fatalf("final state = %q, want acknowledged", st)
	}
}

func TestDirectRedeliveryUntilAcked(t *testing.T) {
	d := newDirectFixture(t)
	al := d.newSOS(t)
	d.srv.fanOutAlert(al, false)
	s := d.open(t, nil)
	s.waitFor(t, "event: push")
	s.cancel() // connection drops before the ack
	s2 := d.open(t, nil)
	s2.waitFor(t, "event: push") // at-least-once: sent again on reconnect
}

func TestDirectLiveDelivery(t *testing.T) {
	d := newDirectFixture(t)
	s := d.open(t, nil)
	s.waitFor(t, "event: hello")
	al := d.newSOS(t)
	d.srv.fanOutAlert(al, false)
	s.waitFor(t, "event: push") // woken by the enqueue, no polling
}

func TestDirectStreamClosesOnRevocation(t *testing.T) {
	t.Run("key revoked", func(t *testing.T) {
		d := newDirectFixture(t)
		s := d.open(t, nil)
		s.waitFor(t, "event: hello")
		if _, err := d.pool.Exec(context.Background(), `UPDATE devices SET ingest_key_hash = NULL WHERE id = $1`, d.dev); err != nil {
			t.Fatal(err)
		}
		s.waitFor(t, "revoked")
		s.closed(t)
	})
	t.Run("logout via revokeIngestKeys", func(t *testing.T) {
		d := newDirectFixture(t)
		s := d.open(t, nil)
		s.waitFor(t, "event: hello")
		if err := d.srv.revokeIngestKeys(context.Background(), d.b); err != nil {
			t.Fatal(err)
		}
		s.closed(t)
	})
	t.Run("device deleted", func(t *testing.T) {
		d := newDirectFixture(t)
		s := d.open(t, nil)
		s.waitFor(t, "event: hello")
		if _, err := d.pool.Exec(context.Background(), `DELETE FROM devices WHERE id = $1`, d.dev); err != nil {
			t.Fatal(err)
		}
		s.waitFor(t, "revoked")
		s.closed(t)
	})
	t.Run("bearer after token version bump", func(t *testing.T) {
		d := newDirectFixture(t)
		tok, _ := d.srv.TM.IssueAccess(d.b, d.f1, 0)
		s := d.open(t, func(r *http.Request) {
			r.Header.Del(middleware.DeviceKeyHeader)
			r.Header.Set("Authorization", "Bearer "+tok)
			r.URL.RawQuery = "device_id=" + d.dev
		})
		s.waitFor(t, "event: hello")
		if _, err := d.pool.Exec(context.Background(), `UPDATE users SET token_version = token_version + 1 WHERE id = $1`, d.b); err != nil {
			t.Fatal(err)
		}
		s.waitFor(t, "revoked")
		s.closed(t)
	})
}

func TestDirectConnectionCapAndReplace(t *testing.T) {
	d := newDirectFixture(t)
	d.broker.MaxConnsPerUser = 1
	// A second device for the same user.
	key2, _ := middleware.GenerateDeviceIngestKey()
	var dev2 string
	if err := d.pool.QueryRow(context.Background(), `
		INSERT INTO devices (user_id, platform, push_transport, ingest_key_hash)
		VALUES ($1,'android','direct',$2) RETURNING id`,
		d.b, middleware.EncodeIngestKeyHash(middleware.HashDeviceIngestKey(key2))).Scan(&dev2); err != nil {
		t.Fatal(err)
	}
	first := d.open(t, nil)
	first.waitFor(t, "event: hello")
	second := d.open(t, func(r *http.Request) { r.Header.Set(middleware.DeviceKeyHeader, dev2+"."+key2) })
	if second.resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("second device status = %d, want 429", second.resp.StatusCode)
	}
	// The same device reconnecting replaces its old stream instead of being refused.
	again := d.open(t, nil)
	if again.resp.StatusCode != 200 {
		t.Fatalf("reconnect status = %d", again.resp.StatusCode)
	}
	first.waitFor(t, "replaced")
	first.closed(t)
}

func TestDirectExpiryRecordsFailedDelivery(t *testing.T) {
	d := newDirectFixture(t)
	al := d.newSOS(t)
	d.srv.fanOutAlert(al, false)
	if _, err := d.pool.Exec(context.Background(),
		`UPDATE push_outbox SET expires_at = now() - interval '1 second' WHERE alert_id = $1`, al.ID); err != nil {
		t.Fatal(err)
	}
	d.srv.expirePushOutbox(context.Background())
	var errCode string
	for _, dl := range d.deliveries(t, al.ID) {
		if dl.Channel == "push" {
			errCode = dl.State + ":" + dl.Error
		}
	}
	if errCode != "failed:expired" {
		t.Fatalf("delivery = %q, want failed:expired", errCode)
	}
}

func TestDirectFallsBackToUnifiedPushWhenOffline(t *testing.T) {
	d := newDirectFixture(t)
	fp := &fakePush{}
	// Wrap: record everything, but still enqueue direct notifications.
	d.srv.Push = dispatchRecorder{inner: d.srv.Push, rec: fp}
	if _, err := d.pool.Exec(context.Background(),
		`UPDATE devices SET unifiedpush_endpoint = 'https://ntfy.example/b' WHERE id = $1`, d.dev); err != nil {
		t.Fatal(err)
	}
	// Offline: queued directly AND sent to the UnifiedPush endpoint.
	al := d.newSOS(t)
	d.srv.fanOutAlert(al, false)
	var direct, up int
	for _, n := range fp.sent {
		if n.Direct {
			direct++
		} else if n.UnifiedPushEndpoint != "" {
			up++
		}
	}
	if direct != 1 || up != 1 {
		t.Fatalf("offline: direct=%d up=%d, want 1/1", direct, up)
	}
	// Connected: only the direct channel is used.
	s := d.open(t, nil)
	s.waitFor(t, "event: hello")
	fp.sent = nil
	al2 := d.newSOS(t)
	d.srv.fanOutAlert(al2, false)
	direct, up = 0, 0
	for _, n := range fp.sent {
		if n.Direct {
			direct++
		} else if n.UnifiedPushEndpoint != "" {
			up++
		}
	}
	if direct != 1 || up != 0 {
		t.Fatalf("connected: direct=%d up=%d, want 1/0", direct, up)
	}
}

// dispatchRecorder records notifications, then delegates only the direct ones
// (so the test never POSTs to a real ntfy host).
type dispatchRecorder struct {
	inner push.Dispatcher
	rec   *fakePush
}

func (r dispatchRecorder) Dispatch(ctx context.Context, n push.Notification) error {
	_ = r.rec.Dispatch(ctx, n)
	if n.Direct {
		return r.inner.Dispatch(ctx, n)
	}
	return nil
}

func TestRegisterDeviceTransport(t *testing.T) {
	d := newDirectFixture(t)
	call := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/devices", strings.NewReader(body))
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: d.c}))
		w := httptest.NewRecorder()
		d.srv.RegisterDevice(w, req)
		return w
	}
	if w := call(`{"platform":"android","name":"p","push_transport":"direct"}`); w.Code != 201 {
		t.Fatalf("register direct = %d %s", w.Code, w.Body)
	}
	var tr string
	_ = d.pool.QueryRow(context.Background(), `SELECT push_transport FROM devices WHERE user_id = $1`, d.c).Scan(&tr)
	if tr != "direct" {
		t.Fatalf("stored transport = %q", tr)
	}
	if w := call(`{"platform":"ios","name":"p","push_transport":"direct"}`); w.Code != 400 {
		t.Fatalf("ios direct = %d, want 400", w.Code)
	}
	d.srv.Direct = nil
	if w := call(`{"platform":"android","name":"p","push_transport":"direct"}`); w.Code != 400 {
		t.Fatalf("direct while disabled = %d, want 400", w.Code)
	}
}
