package handlers

import (
	"bytes"
	"encoding/xml"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

func sliceIter(pts []exportPoint) exportIter {
	return func(yield func(exportPoint) error) error {
		for _, p := range pts {
			if err := yield(p); err != nil {
				return err
			}
		}
		return nil
	}
}

func TestCSVTextNeutralisesFormulas(t *testing.T) {
	cases := map[string]string{
		"":          "",
		"walking":   "walking",
		"=cmd|' /C": `'=cmd|' /C`,
		"+1":        "'+1",
		"-2":        "'-2",
		"@SUM(A1)":  "'@SUM(A1)",
		"a,b":       `"a,b"`,
		`say "hi"`:  `"say ""hi"""`,
		"=1,2":      `"'=1,2"`,
	}
	for in, want := range cases {
		if got := csvText(in); got != want {
			t.Errorf("csvText(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestWriteHistoryCSVKeepsNegativeCoordinatesNumeric(t *testing.T) {
	spd := 3.5
	var buf bytes.Buffer
	err := writeHistoryCSV(&buf, sliceIter([]exportPoint{{
		TS: time.Date(2026, 8, 22, 10, 0, 0, 0, time.UTC), Lat: 35.3, Lon: -94.39,
		Accuracy: 12, SpeedMPS: &spd, MotionState: "=evil()",
	}}))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(buf.String(), "\r\n"), "\r\n")
	if len(lines) != 2 {
		t.Fatalf("lines = %q", lines)
	}
	want := "2026-08-22T10:00:00Z,35.300000,-94.390000,12,3.5,,'=evil()"
	if lines[1] != want {
		t.Fatalf("row = %q, want %q", lines[1], want)
	}
}

func TestWriteHistoryGPXIsWellFormedAndEscaped(t *testing.T) {
	var buf bytes.Buffer
	from := time.Date(2026, 8, 22, 0, 0, 0, 0, time.UTC)
	err := writeHistoryGPX(&buf, `Ann <script>&"x"`, from, from.Add(24*time.Hour), sliceIter([]exportPoint{
		{TS: from.Add(time.Hour), Lat: 35.3, Lon: -94.39},
		{TS: from.Add(2 * time.Hour), Lat: 35.31, Lon: -94.4},
	}))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Name string `xml:"trk>name"`
		Pts  []struct {
			Lat  string `xml:"lat,attr"`
			Lon  string `xml:"lon,attr"`
			Time string `xml:"time"`
		} `xml:"trk>trkseg>trkpt"`
	}
	if err := xml.Unmarshal(buf.Bytes(), &doc); err != nil {
		t.Fatalf("not well-formed: %v\n%s", err, buf.String())
	}
	if len(doc.Pts) != 2 || doc.Pts[0].Lon != "-94.390000" || doc.Pts[0].Time != "2026-08-22T01:00:00Z" {
		t.Fatalf("points = %+v", doc.Pts)
	}
	if !strings.Contains(doc.Name, "<script>") {
		t.Fatalf("name lost its text: %q", doc.Name)
	}
	if strings.Contains(buf.String(), "<script>") {
		t.Fatal("name was not escaped")
	}
}

func TestParseExportRange(t *testing.T) {
	now := time.Date(2026, 8, 22, 18, 0, 0, 0, time.UTC)
	q := func(from, to time.Time) *http.Request {
		return httptest.NewRequest(http.MethodGet,
			"/x?from="+from.Format(time.RFC3339)+"&to="+to.Format(time.RFC3339), nil)
	}
	if _, _, _, ok := parseExportRange(q(now.Add(-30*24*time.Hour), now), now); !ok {
		t.Fatal("30-day range rejected")
	}
	if _, _, _, ok := parseExportRange(q(now.Add(-32*24*time.Hour), now), now); ok {
		t.Fatal("32-day range accepted")
	}
	if _, _, _, ok := parseExportRange(q(now, now.Add(-time.Hour)), now); ok {
		t.Fatal("inverted range accepted")
	}
	if _, _, _, ok := parseExportRange(httptest.NewRequest(http.MethodGet, "/x", nil), now); ok {
		t.Fatal("missing range accepted")
	}
}

func TestAdminExportMemberHistoryUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Get("/api/admin/members/{id}/history/export", srv.AdminExportMemberHistory)
	req := httptest.NewRequest(http.MethodGet,
		"/api/admin/members/u1/history/export?format=csv&from=2026-08-22T00:00:00Z&to=2026-08-23T00:00:00Z", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}
