package handlers

import (
	"net/url"
	"strings"
	"testing"
	"time"
)

func fptr(f float64) *float64 { return &f }
func sptr(s string) *string   { return &s }

const testFamilyID = "11111111-2222-3333-4444-555555555555"

func TestAdminPlaceInputValidate(t *testing.T) {
	good := func() adminPlaceInput {
		return adminPlaceInput{FamilyID: testFamilyID, Name: sptr("  Home "), Lat: fptr(35.3), Lon: fptr(-94.4), RadiusMeters: fptr(150)}
	}
	in := good()
	if msg := in.validate(true); msg != "" {
		t.Fatalf("valid input rejected: %s", msg)
	}
	if *in.Name != "Home" {
		t.Fatalf("name not trimmed: %q", *in.Name)
	}

	cases := map[string]func(*adminPlaceInput){
		"missing family": func(i *adminPlaceInput) { i.FamilyID = "" },
		"bad family":     func(i *adminPlaceInput) { i.FamilyID = "nope" },
		"blank name":     func(i *adminPlaceInput) { i.Name = sptr("   ") },
		"long name":      func(i *adminPlaceInput) { i.Name = sptr(strings.Repeat("x", 101)) },
		"missing lat":    func(i *adminPlaceInput) { i.Lat = nil },
		"lat range":      func(i *adminPlaceInput) { i.Lat = fptr(91) },
		"lon range":      func(i *adminPlaceInput) { i.Lon = fptr(-181) },
		"missing radius": func(i *adminPlaceInput) { i.RadiusMeters = nil },
		"small radius":   func(i *adminPlaceInput) { i.RadiusMeters = fptr(10) },
		"large radius":   func(i *adminPlaceInput) { i.RadiusMeters = fptr(5000) },
		"bad type":       func(i *adminPlaceInput) { i.Type = sptr("castle") },
		"long address":   func(i *adminPlaceInput) { i.Address = sptr(strings.Repeat("a", 501)) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			in := good()
			mutate(&in)
			if in.validate(true) == "" {
				t.Fatal("accepted invalid input")
			}
		})
	}

	// Update is partial: an empty body is fine, a bad field is not.
	empty := adminPlaceInput{}
	if msg := empty.validate(false); msg != "" {
		t.Fatalf("empty update rejected: %s", msg)
	}
	bad := adminPlaceInput{RadiusMeters: fptr(1)}
	if bad.validate(false) == "" {
		t.Fatal("update accepted a tiny radius")
	}
}

func TestParseAuditFilter(t *testing.T) {
	f, msg := parseAuditFilter(url.Values{
		"limit": {"9999"}, "before_id": {"42"}, "user_id": {testFamilyID},
		"action": {"auth."}, "q": {" 100%_ "}, "from": {"2026-10-01"}, "to": {"2026-10-02"},
	})
	if msg != "" {
		t.Fatalf("unexpected error: %s", msg)
	}
	if f.Limit != adminPageMax || f.BeforeID != 42 || f.Text != "100%_" {
		t.Fatalf("bad parse: %+v", f)
	}
	if f.To == nil || !f.To.After(time.Date(2026, 10, 2, 23, 0, 0, 0, time.UTC)) {
		t.Fatalf("bare date in `to` should cover the whole day: %v", f.To)
	}
	where, args := f.where()
	if !strings.Contains(where, "a.id < $1") || !strings.Contains(where, "ESCAPE") || len(args) != 6 {
		t.Fatalf("unexpected where %q args %v", where, args)
	}
	// The user's `%` and `_` must reach the pattern escaped.
	if got := args[3]; got != `%100\%\_%` {
		t.Fatalf("detail pattern not escaped: %v", got)
	}
	if got := args[2]; got != `auth.%` {
		t.Fatalf("prefix pattern: %v", got)
	}

	for _, q := range []url.Values{
		{"before_id": {"abc"}}, {"before_id": {"0"}}, {"user_id": {"x"}},
		{"from": {"yesterday"}}, {"to": {"2026-13-01"}},
		{"action": {strings.Repeat("a", 101)}}, {"q": {strings.Repeat("a", 201)}},
	} {
		if _, msg := parseAuditFilter(q); msg == "" {
			t.Errorf("accepted %v", q)
		}
	}
	if f, _ := parseAuditFilter(url.Values{}); f.Limit != adminPageDefault {
		t.Errorf("default limit %d", f.Limit)
	}
	if where, args := (auditFilter{}).where(); where != "" || len(args) != 0 {
		t.Errorf("empty filter produced %q %v", where, args)
	}
}

func TestParseActivityFilter(t *testing.T) {
	f, msg := parseActivityFilter(url.Values{
		"type": {"arrival, sos,arrival"}, "family_id": {testFamilyID}, "limit": {"10"},
		"before": {"2026-10-27T12:00:00.123456Z"},
	})
	if msg != "" {
		t.Fatalf("unexpected error: %s", msg)
	}
	if len(f.Kinds) != 2 || f.Kinds[0] != "arrival" || f.Kinds[1] != "sos" || f.Limit != 10 || f.Before == nil {
		t.Fatalf("bad parse: %+v", f)
	}
	if f, _ := parseActivityFilter(url.Values{}); f.Kinds != nil {
		t.Errorf("no type should mean every kind, got %v", f.Kinds)
	}
	for _, q := range []url.Values{
		{"type": {"nope"}}, {"family_id": {"x"}}, {"before": {"2026-10-27"}},
	} {
		if _, msg := parseActivityFilter(q); msg == "" {
			t.Errorf("accepted %v", q)
		}
	}
}
