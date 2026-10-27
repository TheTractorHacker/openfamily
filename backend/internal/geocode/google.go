package geocode

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// googleBase is the Google Geocoding API host. It is a fixed constant: the
// operator can only enable it with a key, never point it elsewhere (the URL
// override in Settings exists for tests, like the Census one).
const googleBase = "https://maps.googleapis.com"

const (
	googleTTL = 30 * 24 * time.Hour
	// DefaultGoogleMonthlyCap bounds paid Google requests per calendar month.
	DefaultGoogleMonthlyCap = 3000
	// googleMinQuery is the shortest query (runes) that may reach Google.
	googleMinQuery = 8
)

// googleGeocoder holds the optional, paid Google provider and its monthly
// request budget. The counter lives in memory: it resets on restart (and at
// the UTC month rollover), so a restart can only ever make the cap more
// permissive within the same month by the amount already used.
type googleGeocoder struct {
	base *url.URL
	key  string
	cap  int
	now  func() time.Time

	mu        sync.Mutex
	month     string
	used      int
	capLogged bool
}

func newGoogle(s Settings) (*googleGeocoder, error) {
	key := strings.TrimSpace(s.GoogleAPIKey)
	if key == "" {
		return nil, nil
	}
	raw := googleBase
	if s.GoogleURL != "" {
		raw = s.GoogleURL
	}
	base, err := parseBaseURL(raw, s.AllowPrivate)
	if err != nil {
		return nil, err
	}
	c := s.GoogleMonthlyCap
	if c <= 0 {
		c = DefaultGoogleMonthlyCap
	}
	return &googleGeocoder{base: base, key: key, cap: c, now: time.Now}, nil
}

// take reserves one paid request. It returns false (silently, apart from one
// log line per month) once the monthly cap is used up.
func (g *googleGeocoder) take() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	m := g.now().UTC().Format("2006-01")
	if m != g.month {
		g.month, g.used, g.capLogged = m, 0, false
	}
	if g.used >= g.cap {
		if !g.capLogged {
			g.capLogged = true
			slog.Warn("google geocoding monthly cap reached; using free providers only", "cap", g.cap, "month", m)
		}
		return false
	}
	g.used++
	return true
}

func (g *googleGeocoder) searchURL(address string, b *Point, lang string) string {
	v := url.Values{"address": {address}, "key": {g.key}}
	if lang != "" {
		v.Set("language", lang)
	}
	if b != nil {
		const d = 0.5 // roughly +-50 km: a bias, not a restriction
		v.Set("bounds", strconv.FormatFloat(b.Lat-d, 'f', 3, 64)+","+strconv.FormatFloat(b.Lon-d, 'f', 3, 64)+
			"|"+strconv.FormatFloat(b.Lat+d, 'f', 3, 64)+","+strconv.FormatFloat(b.Lon+d, 'f', 3, 64))
		if looksUS(b) {
			v.Set("region", "us")
		}
	}
	return withPath(g.base, "/maps/api/geocode/json", v)
}

type googleResponse struct {
	Status  string `json:"status"`
	Results []struct {
		Formatted  string   `json:"formatted_address"`
		Types      []string `json:"types"`
		Components []struct {
			Long  string   `json:"long_name"`
			Types []string `json:"types"`
		} `json:"address_components"`
		Geometry struct {
			Location struct {
				Lat float64 `json:"lat"`
				Lng float64 `json:"lng"`
			} `json:"location"`
			LocationType string `json:"location_type"`
		} `json:"geometry"`
		PartialMatch bool `json:"partial_match"`
	} `json:"results"`
}

func hasType(ts []string, want ...string) bool {
	for _, t := range ts {
		for _, w := range want {
			if t == w {
				return true
			}
		}
	}
	return false
}

// parseGoogle normalizes a Geocoding API body. wantHouse says the query had a
// house number: then anything below house level is flagged approximate (the
// app shows "found the street/town, not that house number").
func parseGoogle(body []byte, wantHouse bool) ([]Result, error) {
	var r googleResponse
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, err
	}
	switch r.Status {
	case "OK":
	case "ZERO_RESULTS":
		return nil, nil
	default:
		return nil, &Error{Kind: KindStatus}
	}
	var out []Result
	for _, m := range r.Results {
		lat, lng := m.Geometry.Location.Lat, m.Geometry.Location.Lng
		label := strings.TrimSpace(m.Formatted)
		if !validCoord(lat, lng) || label == "" {
			continue
		}
		lt := m.Geometry.LocationType
		house := hasType(m.Types, "street_address", "premise", "subpremise") ||
			((lt == "ROOFTOP" || lt == "RANGE_INTERPOLATED") && !hasType(m.Types, "route", "locality"))
		res := Result{Label: label, Lat: lat, Lon: lng, Source: "google"}
		var num, route string
		for _, c := range m.Components {
			switch {
			case hasType(c.Types, "street_number"):
				num = c.Long
			case hasType(c.Types, "route"):
				route = c.Long
			}
		}
		res.Name = label
		if route != "" {
			res.Name = streetLine(num, route)
		} else if i := strings.Index(label, ","); i > 0 {
			res.Name = strings.TrimSpace(label[:i])
		}
		switch {
		case house:
			res.Type = "house"
		case hasType(m.Types, "route", "intersection"):
			res.Type = "street"
			if wantHouse {
				res.Approximate, res.Matched = true, "street"
			}
		default:
			res.Type = "city"
			if wantHouse || lt == "APPROXIMATE" || lt == "GEOMETRIC_CENTER" {
				res.Approximate, res.Matched = true, "locality"
			}
		}
		out = append(out, res)
	}
	return out, nil
}

// wantGoogle applies the cost rules. res holds everything free providers found.
func wantGoogle(q string, res []Result, explicit bool) bool {
	if len([]rune(strings.TrimSpace(q))) < googleMinQuery {
		return false
	}
	number := hasHouseNumber(q)
	exact := false
	for _, r := range res {
		if isExactHouse(q, r) {
			exact = true
		}
	}
	if explicit {
		return (number && !exact) || len(res) == 0
	}
	// Typing: only a house-number address that is already two parts long.
	return number && !exact && len(parse(q).parts) >= 2
}

// googleSearch asks Google (or the 30-day cache). ran reports whether Google
// data was used; cached that no paid request was made. Failures and an
// exhausted cap yield no results and no error: free results still stand.
func (s *Service) googleSearch(ctx context.Context, user, q string, b *Point, limit int) (res []Result, cached, ran bool) {
	g := s.goog
	address := strings.Join(parse(q).parts, ", ")
	if address == "" {
		address = q
	}
	key := "g:" + strconv.Itoa(limit) + ":" + NormalizeQuery(address) + biasKey(b)
	if v, ok := s.cache.get(user, key); ok {
		return v.([]Result), true, true
	}
	if !g.take() {
		return nil, false, false
	}
	body, err := doGet(ctx, s.googleClient, s.userAgent, g.searchURL(address, b, s.lang))
	if err != nil {
		return nil, false, true
	}
	r, perr := parseGoogle(body, hasHouseNumber(q))
	if perr != nil {
		return nil, false, true
	}
	if len(r) > limit {
		r = r[:limit]
	}
	s.cache.put(user, key, r, googleTTL)
	return r, false, true
}
