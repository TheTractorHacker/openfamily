package geocode

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestPhotonParsing(t *testing.T) {
	p := photon{}
	rs, err := p.parseSearch(fixture(t, "photon_house.json"))
	if err != nil || len(rs) != 1 {
		t.Fatalf("house: %v %v", rs, err)
	}
	if rs[0].Label != "123 Main Street, Springfield, Illinois" || rs[0].Type != "house" || rs[0].Lat != 39.7990175 || rs[0].Lon != -89.6501483 {
		t.Fatalf("house: %+v", rs[0])
	}
	rs, _ = p.parseSearch(fixture(t, "photon_street.json"))
	if len(rs) != 1 || rs[0].Type != "street" || rs[0].Label != "Maple Avenue, Springfield, Illinois" {
		t.Fatalf("street: %+v", rs)
	}
	rs, _ = p.parseSearch(fixture(t, "photon_poi.json"))
	if len(rs) != 2 { // malformed geometry feature skipped
		t.Fatalf("poi: %+v", rs)
	}
	if rs[0].Type != "poi" || rs[0].Name != "Lincoln Library" || rs[0].Label != "Lincoln Library, 500 E Monroe St, Springfield, Illinois" {
		t.Fatalf("poi: %+v", rs[0])
	}
	if rs[1].Type != "city" || rs[1].Label != "Springfield, Illinois, United States" {
		t.Fatalf("city: %+v", rs[1])
	}
	rs, err = p.parseSearch(fixture(t, "photon_empty.json"))
	if err != nil || len(rs) != 0 {
		t.Fatalf("empty: %v %v", rs, err)
	}
	if _, err = p.parseSearch(fixture(t, "malformed.json")); err == nil {
		t.Fatal("malformed should error")
	}
	a, err := p.parseReverse(fixture(t, "photon_empty.json"))
	if a != nil || err != nil {
		t.Fatalf("reverse empty: %v %v", a, err)
	}
	a, _ = p.parseReverse(fixture(t, "photon_house.json"))
	if a == nil || a.Address != "123 Main Street, Springfield, Illinois" {
		t.Fatalf("reverse: %+v", a)
	}
}

func TestNominatimParsing(t *testing.T) {
	n := nominatim{}
	rs, err := n.parseSearch(fixture(t, "nominatim_search.json"))
	if err != nil || len(rs) != 3 { // bad-coordinate item skipped
		t.Fatalf("search: %v %v", rs, err)
	}
	if rs[0].Type != "house" || rs[0].Label != "123 Main Street, Springfield, Illinois" {
		t.Fatalf("house: %+v", rs[0])
	}
	if rs[1].Type != "street" || rs[1].Label != "Maple Avenue, Springfield, Illinois" {
		t.Fatalf("street: %+v", rs[1])
	}
	if rs[2].Type != "poi" || rs[2].Label != "Lincoln Library, 500 East Monroe Street, Springfield, Illinois" {
		t.Fatalf("poi: %+v", rs[2])
	}
	rs, err = n.parseSearch(fixture(t, "nominatim_empty.json"))
	if err != nil || len(rs) != 0 {
		t.Fatalf("empty: %v %v", rs, err)
	}
	if _, err = n.parseSearch(fixture(t, "malformed.json")); err == nil {
		t.Fatal("malformed should error")
	}
	a, err := n.parseReverse(fixture(t, "nominatim_reverse.json"))
	if err != nil || a == nil || a.Address != "123 Main Street, Springfield, Illinois" {
		t.Fatalf("reverse: %+v %v", a, err)
	}
	a, err = n.parseReverse(fixture(t, "nominatim_reverse_none.json"))
	if a != nil || err != nil {
		t.Fatalf("reverse none: %+v %v", a, err)
	}
}

func TestURLValidation(t *testing.T) {
	bad := []struct {
		url   string
		allow bool
	}{
		{"http://photon.example.com", false},
		{"https://user:pw@photon.example.com", false},
		{"https://127.0.0.1", false},
		{"https://localhost:2322", false},
		{"https://10.0.0.5", false},
		{"https://[::1]", false},
		{"https://169.254.169.254", false},
		{"ftp://example.com", true},
		{"http://8.8.8.8", true}, // cleartext to a public host
		{"https://photon.example.com?x=1", false},
		{"not a url", false},
	}
	for _, c := range bad {
		if _, err := New(Settings{URL: c.url, AllowPrivate: c.allow}); err == nil {
			t.Errorf("%q allow=%v accepted", c.url, c.allow)
		}
	}
	if _, err := New(Settings{URL: "http://127.0.0.1:2322", AllowPrivate: true}); err != nil {
		t.Errorf("private with opt-in: %v", err)
	}
	if _, err := New(Settings{URL: "https://1.1.1.1", Type: "bogus"}); err == nil {
		t.Error("bad type accepted")
	}
	if s, err := New(Settings{}); s != nil || err != nil {
		t.Error("empty URL must disable")
	}
	var nilSvc *Service
	if nilSvc.Enabled() || nilSvc.Autocomplete() {
		t.Error("nil service must be disabled")
	}
}

// A hostname that resolves to loopback must be refused at dial time.
func TestDialTimeSSRFGuard(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("provider must not be reached")
	}))
	defer ts.Close()
	svc, err := New(Settings{URL: "https://1.1.1.1", AllowPrivate: false})
	if err != nil {
		t.Fatal(err)
	}
	// Point the validated service at the loopback server to simulate rebinding.
	u, _ := url.Parse(ts.URL)
	svc.base = u
	svc.client.Transport.(*http.Transport).DialContext = (&dialerFor{allowPrivate: false, cleartext: false}).dial
	if _, _, err := svc.Reverse(context.Background(), "u1", Point{1, 2}); err == nil {
		t.Fatal("loopback target reached")
	}
}

func fake(t *testing.T, typ string, h http.HandlerFunc) (*Service, *httptest.Server) {
	t.Helper()
	ts := httptest.NewServer(h)
	t.Cleanup(ts.Close)
	svc, err := New(Settings{URL: ts.URL, Type: typ, AllowPrivate: true, Version: "1.2.3", Lang: "en"})
	if err != nil {
		t.Fatal(err)
	}
	return svc, ts
}

func TestSearchAndCache(t *testing.T) {
	var hits int32
	var got *http.Request
	svc, _ := fake(t, "photon", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		got = r
		w.Write(fixture(t, "photon_house.json"))
	})
	bias := &Point{39.79901, -89.65014}
	r1, cached, err := svc.Search(context.Background(), "u1", "123  Main St", bias, 5)
	if err != nil || cached || len(r1) != 1 {
		t.Fatalf("%v %v %v", r1, cached, err)
	}
	// Normalized repeat is served from cache.
	_, cached, _ = svc.Search(context.Background(), "u1", " 123 main st ", bias, 5)
	if !cached || atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("cached=%v hits=%d", cached, hits)
	}
	if got.URL.Path != "/api" || got.URL.Query().Get("lang") != "en" || got.URL.Query().Get("lat") != "39.799" {
		t.Fatalf("upstream request: %s", got.URL)
	}
	if ua := got.Header.Get("User-Agent"); ua != "OpenFamily/1.2.3 (self-hosted)" {
		t.Fatalf("UA %q", ua)
	}
	for _, h := range []string{"Authorization", "Cookie", "X-Forwarded-For", "Referer", "X-Real-Ip"} {
		if got.Header.Get(h) != "" {
			t.Errorf("header %s forwarded", h)
		}
	}
}

func TestReverseCacheRoundingAndNotFound(t *testing.T) {
	var hits int32
	var last url.Values
	svc, _ := fake(t, "nominatim", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		last = r.URL.Query()
		if r.URL.Path != "/reverse" || last.Get("format") != "jsonv2" {
			t.Errorf("bad upstream %s", r.URL)
		}
		if last.Get("lat") == "10.00000" {
			w.Write(fixture(t, "nominatim_reverse_none.json"))
			return
		}
		w.Write(fixture(t, "nominatim_reverse.json"))
	})
	a, _, err := svc.Reverse(context.Background(), "u1", Point{39.799012, -89.650148})
	if err != nil || a == nil {
		t.Fatalf("%v %v", a, err)
	}
	if last.Get("lat") != "39.79900" { // rounded before leaving the server
		t.Fatalf("upstream lat %s", last.Get("lat"))
	}
	// ~5 m away: same rounded cell, no new upstream request.
	_, cached, _ := svc.Reverse(context.Background(), "u1", Point{39.799014, -89.650140})
	if !cached || hits != 1 {
		t.Fatalf("cached=%v hits=%d", cached, hits)
	}
	// ~30 m away: new request.
	_, cached, _ = svc.Reverse(context.Background(), "u1", Point{39.79930, -89.65015})
	if cached || hits != 2 {
		t.Fatalf("cached=%v hits=%d", cached, hits)
	}
	a, _, err = svc.Reverse(context.Background(), "u1", Point{10, 10})
	if a != nil || err != nil {
		t.Fatalf("none: %v %v", a, err)
	}
	_, cached, _ = svc.Reverse(context.Background(), "u1", Point{10, 10})
	if !cached {
		t.Fatal("not-found should be cached")
	}
}

func TestCacheTTLAndLRU(t *testing.T) {
	now := time.Unix(0, 0)
	c := newLRU(2, func() time.Time { return now })
	c.put("a", 1, time.Minute)
	c.put("b", 2, time.Minute)
	c.put("c", 3, time.Minute)
	if _, ok := c.get("a"); ok {
		t.Fatal("a should be evicted")
	}
	now = now.Add(2 * time.Minute)
	if _, ok := c.get("b"); ok {
		t.Fatal("b should be expired")
	}
	if c.len() > 2 {
		t.Fatal("overfull")
	}
}

func TestUpstreamFailures(t *testing.T) {
	cases := map[string]struct {
		h    http.HandlerFunc
		want Kind
	}{
		"status": {func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }, KindStatus},
		"redirect": {func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "http://169.254.169.254/", http.StatusFound)
		}, KindStatus},
		"toolarge": {func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte(strings.Repeat("x", MaxResponseBytes+10)))
		}, KindTooLarge},
		"malformed": {func(w http.ResponseWriter, r *http.Request) { w.Write(fixture(t, "malformed.json")) }, KindParse},
	}
	for name, c := range cases {
		svc, _ := fake(t, "photon", c.h)
		_, _, err := svc.Search(context.Background(), "u1", "secret query text", nil, 5)
		ge, ok := err.(*Error)
		if !ok || ge.Kind != c.want {
			t.Errorf("%s: %v", name, err)
		}
		if err != nil && strings.Contains(err.Error(), "secret") {
			t.Errorf("%s: error leaks query", name)
		}
	}
}

func TestPublicNominatimPolicy(t *testing.T) {
	svc, err := New(Settings{URL: "https://nominatim.openstreetmap.org", Type: "nominatim"})
	if err != nil {
		t.Skipf("offline DNS: %v", err) // host check resolves DNS best-effort only
	}
	if svc.Autocomplete() || !svc.Public() {
		t.Fatal("public nominatim must disable autocomplete")
	}
	svc.now = func() time.Time { return time.Unix(100, 0) }
	if !svc.take() || svc.take() {
		t.Fatal("expected 1 request/second gate")
	}
	svc.now = func() time.Time { return time.Unix(101, 1) }
	if !svc.take() {
		t.Fatal("gate should reopen")
	}
}

func TestValidQuery(t *testing.T) {
	for q, ok := range map[string]bool{"ab": false, "abc": true, strings.Repeat("a", 121): false, "a\x00bc": false, "héé": true} {
		if ValidQuery(q) != ok {
			t.Errorf("%q", q)
		}
	}
}

// dialerFor exposes the guarded dial for tests.
type dialerFor struct{ allowPrivate, cleartext bool }

func (d *dialerFor) dial(ctx context.Context, network, addr string) (net.Conn, error) {
	nd := &net.Dialer{Timeout: Timeout, Control: dialControl(d.allowPrivate, d.cleartext)}
	return nd.DialContext(ctx, network, addr)
}

func TestUserCacheIsolationAndFairness(t *testing.T) {
	c := newUserCache(2, 2, nil)
	c.put("a", "k1", 1, time.Hour)
	if _, ok := c.get("b", "k1"); ok {
		t.Fatal("entry leaked across users")
	}
	// One user filling their quota cannot evict another user's entries.
	c.put("b", "x1", 1, time.Hour)
	c.put("b", "x2", 1, time.Hour)
	c.put("b", "x3", 1, time.Hour)
	if _, ok := c.get("a", "k1"); !ok {
		t.Fatal("user b flushed user a")
	}
	if _, ok := c.get("b", "x1"); ok {
		t.Fatal("per-user cap not enforced")
	}
	// The number of tracked users is bounded.
	c.put("c", "k", 1, time.Hour)
	c.put("d", "k", 1, time.Hour)
	if len(c.users) > 2 {
		t.Fatalf("users=%d", len(c.users))
	}
}

func TestServiceCacheIsPerUser(t *testing.T) {
	var hits int32
	svc, _ := fake(t, "photon", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(fixture(t, "photon_house.json"))
	})
	for i := 0; i < 2; i++ {
		svc.Search(context.Background(), "u1", "main st", nil, 5)
		svc.Reverse(context.Background(), "u1", Point{1, 2})
	}
	if hits != 2 {
		t.Fatalf("u1 repeats should be cached, hits=%d", hits)
	}
	svc.Search(context.Background(), "u2", "main st", nil, 5)
	svc.Reverse(context.Background(), "u2", Point{1, 2})
	if hits != 4 {
		t.Fatalf("u2 must cause its own upstream calls, hits=%d", hits)
	}
}
