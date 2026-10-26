package push

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var coordRe = regexp.MustCompile(`-?\d+\.\d{3,}`)

// TestBuildDirectPayload covers payload shape per kind and, for each, that no
// coordinate-looking number or sender name can appear: the payload is only ever
// built from the (already sanitised) title/body, the alert id and a command.
func TestBuildDirectPayload(t *testing.T) {
	cases := []struct {
		name     string
		n        Notification
		kind     string
		wantKeys []string
	}{
		{"alert", Notification{Title: "A family member sent SOS", Body: "A family member sent SOS", AlertID: "7c9e6679-7425-40de-944b-e07fc1f90ae7"}, KindAlert, []string{"v", "id", "kind", "alert_id", "title"}},
		{"alert with body", Notification{Title: "A family member needs help", Body: "A family member needs help: at the gate", AlertID: "a"}, KindAlert, []string{"v", "id", "kind", "alert_id", "title", "body"}},
		{"notice", Notification{Title: "A family member arrived at School"}, KindNotice, []string{"v", "id", "kind", "title"}},
		{"command", Notification{Title: "OpenFamily location refresh", Body: `{"type":"location_request","request_id":"abc"}`, Silent: true}, KindCommand, []string{"v", "id", "kind", "command"}},
		{"command non-json", Notification{Body: "plain", Silent: true}, KindCommand, []string{"v", "id", "kind", "command"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kind, payload, err := BuildDirectPayload(tc.n, "dedupe-1")
			if err != nil {
				t.Fatal(err)
			}
			if kind != tc.kind {
				t.Fatalf("kind = %q, want %q", kind, tc.kind)
			}
			var m map[string]json.RawMessage
			if err := json.Unmarshal(payload, &m); err != nil {
				t.Fatal(err)
			}
			if len(m) != len(tc.wantKeys) {
				t.Errorf("keys = %v, want %v", m, tc.wantKeys)
			}
			for _, k := range tc.wantKeys {
				if _, ok := m[k]; !ok {
					t.Errorf("missing key %q in %s", k, payload)
				}
			}
			for _, bad := range []string{"lat", "lon", "latitude", "longitude", "name", "sender"} {
				if _, ok := m[bad]; ok {
					t.Errorf("payload has forbidden key %q: %s", bad, payload)
				}
			}
			if coordRe.Match(payload) {
				t.Errorf("payload looks like it contains coordinates: %s", payload)
			}
		})
	}
}

func TestDirectConnectCapAndReplace(t *testing.T) {
	b := &DirectBroker{MaxConnsPerUser: 2, conns: map[string]*DirectConn{}}
	c1, err := b.Connect("u", "d1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.Connect("u", "d2"); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Connect("u", "d3"); err != ErrTooManyConnections {
		t.Fatalf("third device: err = %v, want ErrTooManyConnections", err)
	}
	if _, err := b.Connect("other", "d9"); err != nil {
		t.Fatalf("other user must not be capped: %v", err)
	}
	// Reconnecting the same device replaces the old stream and is not capped.
	c1b, err := b.Connect("u", "d1")
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-c1.Done():
	default:
		t.Fatal("old connection of the same device was not closed")
	}
	c1.Close() // must not unregister the replacement
	if !b.IsConnected("d1") {
		t.Fatal("replacement connection lost")
	}
	b.CloseUser("u")
	select {
	case <-c1b.Done():
	default:
		t.Fatal("CloseUser did not close the stream")
	}
	if b.IsConnected("d1") || b.IsConnected("d2") {
		t.Fatal("streams still registered after CloseUser")
	}
	var nilBroker *DirectBroker
	if nilBroker.IsConnected("x") {
		t.Fatal("nil broker reports a connection")
	}
	nilBroker.CloseDevice("x") // must not panic
}

func TestDispatchDirectDisabled(t *testing.T) {
	d := &DispatcherImpl{}
	err := d.Dispatch(context.Background(), Notification{Direct: true, DeviceID: "d", UserID: "u", Platform: "android"})
	if err == nil || !IsPermanent(err) {
		t.Fatalf("err = %v, want permanent error", err)
	}
}

// --- real Postgres ---

type outboxFixture struct {
	pool   *pgxpool.Pool
	b      *DirectBroker
	user   string
	device string
}

func newOutboxFixture(t *testing.T) *outboxFixture {
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
	t.Cleanup(pool.Close)
	tag := fmt.Sprint(time.Now().UnixNano())
	f := &outboxFixture{pool: pool, b: NewDirectBroker(pool)}
	if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,'U','x') RETURNING id`,
		"push"+tag+"@example.com").Scan(&f.user); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, f.user) })
	if err := pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, push_transport) VALUES ($1,'android','direct') RETURNING id`,
		f.user).Scan(&f.device); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *outboxFixture) note(id string) Notification {
	return Notification{Title: "A family member arrived at School", Direct: true, DeviceID: f.device, UserID: f.user, DedupeID: id}
}

func TestOutboxQueueAckDedupe(t *testing.T) {
	f := newOutboxFixture(t)
	ctx := context.Background()
	for _, id := range []string{"e1", "e2", "e1"} { // e1 twice: deduplicated
		if err := f.b.Enqueue(ctx, f.note(id)); err != nil {
			t.Fatal(err)
		}
	}
	evs, err := f.b.Pending(ctx, f.device, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 || evs[0].DedupeID != "e1" || evs[1].DedupeID != "e2" {
		t.Fatalf("pending = %+v, want e1,e2 in order", evs)
	}
	// Sent but unacked events stay pending (re-sent on reconnect).
	if err := f.b.MarkSent(ctx, evs[0].ID); err != nil {
		t.Fatal(err)
	}
	if evs, _ = f.b.Pending(ctx, f.device, 10); len(evs) != 2 {
		t.Fatalf("sent-unacked event must stay pending, got %d", len(evs))
	}
	acked, err := f.b.Ack(ctx, f.device, []string{"e1", "nope"})
	if err != nil || len(acked) != 1 || acked[0].DedupeID != "e1" {
		t.Fatalf("ack = %+v, %v", acked, err)
	}
	if acked, _ = f.b.Ack(ctx, f.device, []string{"e1"}); len(acked) != 0 {
		t.Fatalf("second ack must be a no-op, got %+v", acked)
	}
	// Re-enqueueing an acked id does not resurrect it.
	_ = f.b.Enqueue(ctx, f.note("e1"))
	if evs, _ = f.b.Pending(ctx, f.device, 10); len(evs) != 1 || evs[0].DedupeID != "e2" {
		t.Fatalf("pending after ack = %+v, want only e2", evs)
	}
	// Another device cannot ack this device's events.
	if acked, _ = f.b.Ack(ctx, "00000000-0000-0000-0000-000000000000", []string{"e2"}); len(acked) != 0 {
		t.Fatalf("foreign ack accepted: %+v", acked)
	}
}

func TestOutboxTTLAndBound(t *testing.T) {
	f := newOutboxFixture(t)
	ctx := context.Background()
	if err := f.b.Enqueue(ctx, f.note("old")); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `UPDATE push_outbox SET expires_at = now() - interval '1 minute' WHERE dedupe_id = 'old' AND device_id = $1`, f.device); err != nil {
		t.Fatal(err)
	}
	if evs, _ := f.b.Pending(ctx, f.device, 10); len(evs) != 0 {
		t.Fatalf("expired event still pending: %+v", evs)
	}
	expired, err := f.b.ExpireDue(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, e := range expired {
		found = found || (e.DeviceID == f.device && e.DedupeID == "old")
	}
	if !found {
		t.Fatalf("ExpireDue did not report the expired row: %+v", expired)
	}

	f.b.MaxQueuePerDevice = 3
	for i := 0; i < 6; i++ {
		if err := f.b.Enqueue(ctx, f.note(fmt.Sprintf("n%d", i))); err != nil {
			t.Fatal(err)
		}
		time.Sleep(2 * time.Millisecond)
	}
	evs, _ := f.b.Pending(ctx, f.device, 50)
	if len(evs) != 3 || evs[0].DedupeID != "n3" || evs[2].DedupeID != "n5" {
		var ids []string
		for _, e := range evs {
			ids = append(ids, e.DedupeID)
		}
		t.Fatalf("bounded queue = %v, want the newest three n3..n5", ids)
	}
}

func TestOutboxPayloadStoredWithoutCoordinates(t *testing.T) {
	f := newOutboxFixture(t)
	ctx := context.Background()
	n := f.note("sos1")
	n.Title, n.Body = "A family member sent SOS", "A family member sent SOS"
	if err := f.b.Enqueue(ctx, n); err != nil {
		t.Fatal(err)
	}
	rows, err := f.pool.Query(ctx, `SELECT payload::text FROM push_outbox WHERE device_id = $1`, f.device)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var p string
		_ = rows.Scan(&p)
		if coordRe.MatchString(p) || strings.Contains(p, "lat") || strings.Contains(p, "lon") {
			t.Errorf("stored payload leaks location: %s", p)
		}
	}
}

func TestEnqueueWakesConnection(t *testing.T) {
	f := newOutboxFixture(t)
	c, err := f.b.Connect(f.user, f.device)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := f.b.Enqueue(context.Background(), f.note("w1")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-c.Wake():
	case <-time.After(time.Second):
		t.Fatal("connection was not woken")
	}
}
