// Package geocode is a privacy-preserving geocoding proxy: it talks to one
// operator-configured Photon- or Nominatim-compatible provider on behalf of
// signed-in users, so phones never contact a third party directly.
//
// Nothing in this package logs query text or coordinates, and every error it
// returns is a sanitized *Error (the underlying net/http errors embed the full
// request URL, which contains the query).
package geocode

import (
	"context"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	// Timeout bounds every upstream call.
	Timeout = 4 * time.Second
	// MaxResponseBytes caps what is read from the provider.
	MaxResponseBytes = 256 << 10

	cacheSizePerUser = 64
	maxCacheUsers    = 1000
	searchTTL        = time.Hour
	reverseTTL       = 24 * time.Hour
	publicNominatim  = "nominatim.openstreetmap.org"
)

// Kind classifies a sanitized upstream failure.
type Kind string

const (
	KindUnavailable Kind = "unavailable"
	KindTimeout     Kind = "timeout"
	KindStatus      Kind = "bad_status"
	KindTooLarge    Kind = "too_large"
	KindParse       Kind = "parse"
	KindBusy        Kind = "busy"
)

// Error carries no URL, query or coordinates, so it is safe to log.
type Error struct{ Kind Kind }

func (e *Error) Error() string { return "geocoder " + string(e.Kind) }

// ErrBusy is returned when the public-Nominatim 1 request/second policy gate
// refuses a call.
var ErrBusy = &Error{Kind: KindBusy}

// Settings configures a Service.
type Settings struct {
	URL          string
	Type         string // "photon" (default) or "nominatim"
	Lang         string
	AllowPrivate bool
	Version      string // build version for the User-Agent
}

// Service is a configured provider client with cache.
type Service struct {
	base         *url.URL
	prov         provider
	lang         string
	userAgent    string
	client       *http.Client
	cache        *userCache
	autocomplete bool

	// public Nominatim policy: at most one upstream request per second.
	policyGate bool
	gateMu     sync.Mutex
	gateLast   time.Time
	now        func() time.Time
}

// New validates settings and builds a Service. An empty URL yields (nil, nil):
// the feature is disabled.
func New(s Settings) (*Service, error) {
	if strings.TrimSpace(s.URL) == "" {
		return nil, nil
	}
	base, err := parseBaseURL(s.URL, s.AllowPrivate)
	if err != nil {
		return nil, err
	}
	var prov provider
	switch strings.ToLower(strings.TrimSpace(s.Type)) {
	case "", "photon":
		prov = photon{}
	case "nominatim":
		prov = nominatim{}
	default:
		return nil, errors.New("GEOCODER_TYPE must be photon or nominatim")
	}
	_, isNom := prov.(nominatim)
	public := isNom && strings.EqualFold(base.Hostname(), publicNominatim)
	lang := strings.TrimSpace(s.Lang)
	if len(lang) > 16 || strings.ContainsAny(lang, " &=?#\r\n") {
		return nil, errors.New("GEOCODER_LANG is not a valid language tag")
	}
	v := s.Version
	if v == "" {
		v = "dev"
	}
	dialer := &net.Dialer{
		Timeout: Timeout,
		Control: dialControl(s.AllowPrivate, base.Scheme == "http"),
	}
	tr := &http.Transport{
		Proxy:                 nil, // never route through an environment proxy
		DialContext:           dialer.DialContext,
		TLSHandshakeTimeout:   Timeout,
		ResponseHeaderTimeout: Timeout,
		MaxIdleConns:          4,
		IdleConnTimeout:       30 * time.Second,
		DisableCompression:    false,
	}
	return &Service{
		base:      base,
		prov:      prov,
		lang:      lang,
		userAgent: "OpenFamily/" + v + " (self-hosted)",
		client: &http.Client{
			Transport: tr,
			Timeout:   Timeout,
			// Never follow redirects: a provider must not bounce us to another host.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		cache:        newUserCache(maxCacheUsers, cacheSizePerUser, nil),
		autocomplete: !public,
		policyGate:   public,
		now:          time.Now,
	}, nil
}

// Enabled reports whether the service can answer requests (nil-safe).
func (s *Service) Enabled() bool { return s != nil }

// Autocomplete reports whether search-as-you-type is allowed (nil-safe).
func (s *Service) Autocomplete() bool { return s != nil && s.autocomplete }

// Public reports whether the provider is the public nominatim.openstreetmap.org.
func (s *Service) Public() bool { return s != nil && s.policyGate }

// NormalizeQuery lower-cases and collapses whitespace.
func NormalizeQuery(q string) string {
	return strings.ToLower(strings.Join(strings.Fields(q), " "))
}

// ValidQuery reports whether q (trimmed) is 3..120 runes with no control chars.
func ValidQuery(q string) bool {
	n := 0
	for _, r := range q {
		if unicode.IsControl(r) {
			return false
		}
		n++
	}
	return n >= 3 && n <= 120
}

func round(v float64, places int) float64 {
	p := math.Pow(10, float64(places))
	return math.Round(v*p) / p
}

// Search runs a forward lookup. Results are cached per user (never shared
// across users) and upstream calls are never coalesced between users. The bias point is rounded to ~1 km before it
// is sent upstream. cached reports a cache hit.
func (s *Service) Search(ctx context.Context, user, q string, bias *Point, limit int) (res []Result, cached bool, err error) {
	q = strings.Join(strings.Fields(q), " ")
	if limit < 1 {
		limit = 5
	}
	if limit > 8 {
		limit = 8
	}
	var b *Point
	key := "s:" + strconv.Itoa(limit) + ":" + NormalizeQuery(q)
	if bias != nil {
		b = &Point{round(bias.Lat, 2), round(bias.Lon, 2)}
		key += ":" + strconv.FormatFloat(b.Lat, 'f', 2, 64) + "," + strconv.FormatFloat(b.Lon, 'f', 2, 64)
	}
	if v, ok := s.cache.get(user, key); ok {
		return v.([]Result), true, nil
	}
	body, err := s.fetch(ctx, s.prov.searchURL(s.base, q, b, limit, s.lang))
	if err != nil {
		return nil, false, err
	}
	res, perr := s.prov.parseSearch(body)
	if perr != nil {
		return nil, false, &Error{Kind: KindParse}
	}
	if len(res) > limit {
		res = res[:limit]
	}
	s.cache.put(user, key, res, searchTTL)
	return res, false, nil
}

// Reverse looks up the address at p, rounded to 4 decimals (~11 m) both for the
// cache key and for what is sent upstream. A nil Address with nil error means
// "no address found" (also cached).
func (s *Service) Reverse(ctx context.Context, user string, p Point) (addr *Address, cached bool, err error) {
	rp := Point{round(p.Lat, 4), round(p.Lon, 4)}
	key := "r:" + strconv.FormatFloat(rp.Lat, 'f', 4, 64) + "," + strconv.FormatFloat(rp.Lon, 'f', 4, 64)
	if v, ok := s.cache.get(user, key); ok {
		a, _ := v.(*Address)
		return a, true, nil
	}
	body, err := s.fetch(ctx, s.prov.reverseURL(s.base, rp, s.lang))
	if err != nil {
		return nil, false, err
	}
	a, perr := s.prov.parseReverse(body)
	if perr != nil {
		return nil, false, &Error{Kind: KindParse}
	}
	if a != nil {
		a.Lat, a.Lon = p.Lat, p.Lon // echo the pin the user dropped
	}
	ttl := reverseTTL
	if a == nil {
		ttl = 10 * time.Minute
	}
	s.cache.put(user, key, a, ttl)
	return a, false, nil
}

func (s *Service) take() bool {
	if !s.policyGate {
		return true
	}
	s.gateMu.Lock()
	defer s.gateMu.Unlock()
	now := s.now()
	if now.Sub(s.gateLast) < time.Second {
		return false
	}
	s.gateLast = now
	return true
}

// fetch performs one GET with only a User-Agent and Accept header: no cookies,
// tokens, Referer or client-address headers are ever forwarded.
func (s *Service) fetch(ctx context.Context, target string) ([]byte, error) {
	if !s.take() {
		return nil, ErrBusy
	}
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, &Error{Kind: KindUnavailable}
	}
	req.Header.Set("User-Agent", s.userAgent)
	req.Header.Set("Accept", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || isTimeout(err) {
			return nil, &Error{Kind: KindTimeout}
		}
		return nil, &Error{Kind: KindUnavailable}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, &Error{Kind: KindStatus}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes+1))
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || isTimeout(err) {
			return nil, &Error{Kind: KindTimeout}
		}
		return nil, &Error{Kind: KindUnavailable}
	}
	if len(body) > MaxResponseBytes {
		return nil, &Error{Kind: KindTooLarge}
	}
	return body, nil
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}
