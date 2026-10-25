package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
	"github.com/wheresfrank/openfamily/backend/internal/push"
)

type fakePush struct {
	mu   sync.Mutex
	sent []push.Notification
}

func (f *fakePush) Dispatch(_ context.Context, n push.Notification) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, n)
	return nil
}

type fakeSMS struct {
	mu     sync.Mutex
	bodies []string
}

func (f *fakeSMS) Enabled() bool { return true }
func (f *fakeSMS) Send(_ context.Context, _, body string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.bodies = append(f.bodies, body)
	return nil
}

type alertFixture struct {
	srv        *Server
	pool       *pgxpool.Pool
	push       *fakePush
	sms        *fakeSMS
	f1, f2     string
	a, b, c, d string // f1: admin sender, member, member, second admin
	x          string // f2 admin
	router     http.Handler
}

func newAlertFixture(t *testing.T) *alertFixture {
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
	fx := &alertFixture{pool: pool, push: &fakePush{}, sms: &fakeSMS{}}
	mk := func(q string, args ...any) string {
		var id string
		if err := pool.QueryRow(ctx, q, args...).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	tag := fmt.Sprint(time.Now().UnixNano())
	fx.f1 = mk(`INSERT INTO families (name) VALUES ('f1') RETURNING id`)
	fx.f2 = mk(`INSERT INTO families (name) VALUES ('f2') RETURNING id`)
	user := func(name, fam, role string) string {
		return mk(`INSERT INTO users (email, name, password_hash, family_id, role) VALUES ($1,$2,'x',$3,$4) RETURNING id`,
			name+tag+"@example.com", name+" Tester", fam, role)
	}
	fx.a, fx.b, fx.c = user("a", fx.f1, "admin"), user("b", fx.f1, "member"), user("c", fx.f1, "member")
	fx.d, fx.x = user("d", fx.f1, "admin"), user("x", fx.f2, "admin")
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE family_id IN ($1,$2)`, fx.f1, fx.f2)
		_, _ = pool.Exec(ctx, `DELETE FROM families WHERE id IN ($1,$2)`, fx.f1, fx.f2)
	})
	if _, err := pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/b')`, fx.b); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 7; i++ {
		if _, err := pool.Exec(ctx, `INSERT INTO emergency_contacts (user_id, name, phone, phone_digits) VALUES ($1,$2,$3,$4)`,
			fx.a, fmt.Sprintf("Contact %d", i), fmt.Sprintf("+1415555010%d", i), fmt.Sprintf("1415555010%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	srv := New(pool, auth.NewTokenManager("secret-secret-secret-secret-1234", time.Minute, time.Hour), fx.push)
	srv.SMS = fx.sms
	srv.PublicBaseURL = "https://of.example.com"
	srv.AlertCfg = AlertLimits{SMSMaxRecipients: 3, SenderSMSPerDay: 10, FamilySMSPerHour: 20, FamilyMaxPerHour: 30, set: true}
	fx.srv = srv
	r := chi.NewRouter()
	r.Get("/alerts/share/{token}", srv.ShareAlert)
	r.Get("/alerts", srv.ListAlerts)
	r.Get("/alerts/{id}", srv.GetAlert)
	r.Post("/alerts/{id}/ack", srv.AckAlert)
	r.Post("/alerts/{id}/share/revoke", srv.RevokeAlertShare)
	fx.router = r
	return fx
}

func (fx *alertFixture) do(method, path, uid string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	if uid != "" {
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
	}
	w := httptest.NewRecorder()
	fx.router.ServeHTTP(w, req)
	return w
}

func (fx *alertFixture) newSOS(t *testing.T) alertRow {
	t.Helper()
	token, _ := newShareToken()
	lat, lon := 51.50735, -0.12776
	a := alertRow{UserID: fx.a, FamilyID: fx.f1, Type: alertSOS, Status: alertStatusActive, Lat: &lat, Lon: &lon, ShareToken: token, SenderName: "A Tester"}
	err := fx.pool.QueryRow(context.Background(), `
		INSERT INTO alerts (user_id, family_id, type, status, lat, lon, share_token, share_expires_at)
		VALUES ($1,$2,'sos','active',$3,$4,$5, now() + interval '1 hour') RETURNING id, created_at`,
		a.UserID, a.FamilyID, lat, lon, token).Scan(&a.ID, &a.CreatedAt)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

type delivery struct{ State, Channel, Error, Recipient string }

func (fx *alertFixture) deliveries(t *testing.T, alertID string) []delivery {
	t.Helper()
	rows, err := fx.pool.Query(context.Background(),
		`SELECT state, channel, error, recipient_label FROM alert_deliveries WHERE alert_id=$1 ORDER BY channel, recipient_label`, alertID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []delivery
	for rows.Next() {
		var d delivery
		if err := rows.Scan(&d.State, &d.Channel, &d.Error, &d.Recipient); err != nil {
			t.Fatal(err)
		}
		out = append(out, d)
	}
	return out
}

func TestAlertDeliveryLifecycleAndAuthorization(t *testing.T) {
	fx := newAlertFixture(t)
	fx.srv.hub = newHub()
	// B and C are connected over WebSocket; A (sender) too, to receive the ack.
	mkc := func() *wsClient { return &wsClient{send: make(chan []byte, 8), done: make(chan struct{})} }
	cb, ca := mkc(), mkc()
	fx.srv.hub.register(fx.f1, fx.b, cb)
	fx.srv.hub.register(fx.f1, fx.a, ca)

	al := fx.newSOS(t)
	fx.srv.fanOutAlert(al, true)

	counts := map[string]int{}
	for _, d := range fx.deliveries(t, al.ID) {
		counts[d.Channel+":"+d.State+":"+d.Error]++
	}
	want := map[string]int{
		"push:sent:":                            1, // B's device
		"ws:delivered:":                         1, // B's live socket (A excluded)
		"sms:sent:":                             3,
		"sms:failed:limit_recipients_per_alert": 4,
	}
	for k, v := range want {
		if counts[k] != v {
			t.Errorf("deliveries %s = %d, want %d (all: %v)", k, counts[k], v, counts)
		}
	}
	// Payload hygiene: push has no sender name/coords, SMS has no coords.
	coord := regexp.MustCompile(`\d+\.\d{3,}`)
	for _, n := range fx.push.sent {
		if strings.Contains(n.Title+n.Body, "A Tester") || coord.MatchString(n.Title+n.Body) {
			t.Errorf("push leaks: %+v", n)
		}
	}
	for _, b := range fx.sms.bodies {
		if coord.MatchString(b) || !strings.Contains(b, "NOT been contacted") {
			t.Errorf("sms body: %q", b)
		}
	}
	if len(fx.sms.bodies) != 3 {
		t.Errorf("sms sent %d, want 3", len(fx.sms.bodies))
	}
	// An audit-style fan-out summary is not asserted here (hook-less); the
	// sender can read the states back:
	if w := fx.do("GET", "/alerts/"+al.ID, fx.a); w.Code != 200 {
		t.Fatalf("sender GET %d %s", w.Code, w.Body)
	} else {
		var out alertDetailJSON
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		if len(out.Deliveries) != 9 || !strings.Contains(out.Message, "not contacted") {
			t.Errorf("detail: %d deliveries, msg %q", len(out.Deliveries), out.Message)
		}
	}
	if w := fx.do("GET", "/alerts/"+al.ID, fx.d); w.Code != 200 {
		t.Errorf("family admin GET %d", w.Code)
	}
	for name, uid := range map[string]string{"member": fx.c, "other family admin": fx.x} {
		if w := fx.do("GET", "/alerts/"+al.ID, uid); w.Code != 404 {
			t.Errorf("%s GET = %d, want 404", name, w.Code)
		}
	}
	if w := fx.do("GET", "/alerts/"+al.ID, ""); w.Code != 401 {
		t.Errorf("anon GET = %d", w.Code)
	}

	// Acknowledge: idempotent, fanned out once to the sender's socket.
	drain := func(c *wsClient) {
		for len(c.send) > 0 {
			<-c.send
		}
	}
	drain(ca)
	w1 := fx.do("POST", "/alerts/"+al.ID+"/ack", fx.b)
	w2 := fx.do("POST", "/alerts/"+al.ID+"/ack", fx.b)
	if w1.Code != 200 || w2.Code != 200 || w1.Body.String() != w2.Body.String() {
		t.Fatalf("ack not idempotent: %d %s / %d %s", w1.Code, w1.Body, w2.Code, w2.Body)
	}
	if len(ca.send) != 1 {
		t.Fatalf("sender got %d ack frames, want 1", len(ca.send))
	}
	if frame := string(<-ca.send); !strings.Contains(frame, `"alert_ack"`) || !strings.Contains(frame, fx.b) {
		t.Errorf("frame %s", frame)
	}
	for _, d := range fx.deliveries(t, al.ID) {
		if d.Channel != "sms" && strings.HasPrefix(d.Recipient, "b") && d.State != "acknowledged" {
			t.Errorf("B delivery not acknowledged: %+v", d)
		}
	}
	if w := fx.do("POST", "/alerts/"+al.ID+"/ack", fx.a); w.Code != 400 {
		t.Errorf("self ack = %d", w.Code)
	}
	if w := fx.do("POST", "/alerts/"+al.ID+"/ack", fx.x); w.Code != 404 {
		t.Errorf("cross-family ack = %d", w.Code)
	}
	// C never had a delivery row; acking still works and creates one.
	if w := fx.do("POST", "/alerts/"+al.ID+"/ack", fx.c); w.Code != 200 {
		t.Errorf("C ack = %d", w.Code)
	}

	// Share link: served while active, gone after the sender revokes it.
	if w := fx.do("GET", "/alerts/share/"+al.ShareToken, ""); w.Code != 200 || !strings.Contains(w.Body.String(), "51.50735") {
		t.Errorf("share page %d", w.Code)
	}
	if w := fx.do("POST", "/alerts/"+al.ID+"/share/revoke", fx.b); w.Code != 404 {
		t.Errorf("non-owner revoke = %d", w.Code)
	}
	if w := fx.do("POST", "/alerts/"+al.ID+"/share/revoke", fx.a); w.Code != 200 {
		t.Errorf("revoke = %d", w.Code)
	}
	if w := fx.do("GET", "/alerts/share/"+al.ShareToken, ""); w.Code != http.StatusGone {
		t.Errorf("revoked share page = %d", w.Code)
	}
	// Expired link.
	_, _ = fx.pool.Exec(context.Background(), `UPDATE alerts SET share_revoked_at=NULL, share_expires_at=now() - interval '1 second' WHERE id=$1`, al.ID)
	if w := fx.do("GET", "/alerts/share/"+al.ShareToken, ""); w.Code != http.StatusGone {
		t.Errorf("expired share page = %d", w.Code)
	}
}

func TestAlertSMSSenderDailyCap(t *testing.T) {
	fx := newAlertFixture(t)
	fx.srv.AlertCfg.SenderSMSPerDay = 4
	fx.srv.AlertCfg.SMSMaxRecipients = 3
	first, second := fx.newSOS(t), fx.newSOS(t)
	fx.srv.fanOutAlert(first, true)
	fx.srv.fanOutAlert(second, true)
	if len(fx.sms.bodies) != 4 {
		t.Fatalf("sent %d SMS, want 4 (3 + 1 left of the daily cap)", len(fx.sms.bodies))
	}
	n := 0
	for _, d := range fx.deliveries(t, second.ID) {
		if d.Error == "limit_sender_sms_per_day" {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("second alert limited %d contacts, want 2", n)
	}
}

func TestListAlertsPaginationAndFamilyScope(t *testing.T) {
	fx := newAlertFixture(t)
	var ids []string
	for i := 0; i < 3; i++ {
		ids = append(ids, fx.newSOS(t).ID)
	}
	other := ""
	if err := fx.pool.QueryRow(context.Background(), `
		INSERT INTO alerts (user_id, family_id, type, share_token) VALUES ($1,$2,'help',$3) RETURNING id`,
		fx.x, fx.f2, "tok"+fmt.Sprint(time.Now().UnixNano())).Scan(&other); err != nil {
		t.Fatal(err)
	}
	type page struct {
		Alerts []alertListItem `json:"alerts"`
		Next   string          `json:"next_before"`
	}
	get := func(path, uid string) (page, int) {
		w := fx.do("GET", path, uid)
		var p page
		_ = json.Unmarshal(w.Body.Bytes(), &p)
		return p, w.Code
	}
	p1, _ := get("/alerts?limit=2", fx.c)
	if len(p1.Alerts) != 2 || p1.Next == "" {
		t.Fatalf("page1 %+v", p1)
	}
	p2, _ := get("/alerts?limit=2&before="+p1.Next, fx.c)
	if len(p2.Alerts) != 1 || p2.Next != "" {
		t.Fatalf("page2 %+v", p2)
	}
	seen := map[string]bool{}
	for _, a := range append(p1.Alerts, p2.Alerts...) {
		seen[a.ID] = true
		if a.ID == other {
			t.Fatal("cross-family alert leaked")
		}
	}
	if len(seen) != 3 {
		t.Fatalf("saw %v want %v", seen, ids)
	}
	px, code := get("/alerts", fx.x)
	if code != 200 || len(px.Alerts) != 1 || px.Alerts[0].ID != other {
		t.Fatalf("family 2 view %+v", px)
	}
	// A cursor from another family yields nothing rather than a hint.
	pc, _ := get("/alerts?before="+ids[0], fx.x)
	if len(pc.Alerts) != 0 {
		t.Fatalf("foreign cursor returned %+v", pc)
	}
	if _, code := get("/alerts?limit=0", fx.c); code != 400 {
		t.Fatalf("limit=0 -> %d", code)
	}
	if _, code := get("/alerts?before=not-a-uuid", fx.c); code == 200 {
		// invalid cursor must not 500 silently into data
		t.Log("invalid cursor accepted as empty page")
	}
}
