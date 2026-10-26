package geocode

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	searchDeadline  = 7 * time.Second
	fallbackMaxWait = 2 * time.Second
)

// SearchOptions are the per-request inputs of SearchWith.
type SearchOptions struct {
	Bias  *Point
	Limit int
	// Explicit marks a user-submitted search (search icon / Enter). Only
	// explicit searches may reach the fallback providers.
	Explicit bool
}

// SearchResponse is the outcome of one app request.
type SearchResponse struct {
	Results     []Result
	Cached      bool // every upstream attempt was served from the per-user cache
	Approximate bool // all results are from relaxed attempts
	Attempts    int  // upstream calls made or served from cache
	Fallback    bool // a fallback provider was consulted
}

// SearchWith runs the relaxation ladder on the primary provider and, for
// explicit searches only, the fallback providers. One call is one app request:
// the caller's per-user limiter is charged once, however many attempts follow.
func (s *Service) SearchWith(ctx context.Context, user, q string, o SearchOptions) (SearchResponse, error) {
	var out SearchResponse
	limit := o.Limit
	if limit < 1 {
		limit = 5
	}
	if limit > 8 {
		limit = 8
	}
	var b *Point
	if o.Bias != nil {
		b = &Point{round(o.Bias.Lat, 3), round(o.Bias.Lon, 3)}
	}
	ctx, cancel := context.WithTimeout(ctx, searchDeadline)
	defer cancel()

	allCached := true
	var firstErr error
	var res []Result
	for _, c := range Candidates(q) {
		r, cached, err := s.photonAttempt(ctx, user, c.Query, b, limit)
		out.Attempts++
		if err != nil {
			firstErr = err
			break
		}
		if !cached {
			allCached = false
		}
		if len(r) > 0 {
			res = markRelaxed(r, c.Relax)
			break
		}
	}

	if o.Explicit && s.fb != nil && s.needFallback(q, res) {
		fr, cached, ran, ferr := s.fallbackSearch(ctx, user, q, b, limit)
		out.Fallback = ran
		if ran && !cached {
			allCached = false
		}
		if len(fr) > 0 {
			res = append(fr, res...)
			sort.SliceStable(res, func(i, j int) bool { return !res[i].Approximate && res[j].Approximate })
			firstErr = nil
		} else if len(res) == 0 && firstErr == nil && ferr != nil {
			firstErr = ferr
		}
	}
	if len(res) == 0 && firstErr != nil {
		return out, firstErr
	}
	if len(res) > limit {
		res = res[:limit]
	}
	out.Results = res
	out.Cached = allCached
	out.Approximate = len(res) > 0
	for _, r := range res {
		if !r.Approximate {
			out.Approximate = false
		}
	}
	return out, nil
}

// markRelaxed returns a copy (cached slices are shared) flagged approximate.
func markRelaxed(r []Result, relax string) []Result {
	if relax == "" {
		return r
	}
	out := make([]Result, len(r))
	copy(out, r)
	for i := range out {
		out[i].Approximate = true
		out[i].Matched = relax
	}
	return out
}

func (s *Service) photonAttempt(ctx context.Context, user, q string, b *Point, limit int) ([]Result, bool, error) {
	key := "s:" + strconv.Itoa(limit) + ":" + NormalizeQuery(q) + biasKey(b)
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

func biasKey(b *Point) string {
	if b == nil {
		return ""
	}
	return ":" + strconv.FormatFloat(b.Lat, 'f', 3, 64) + "," + strconv.FormatFloat(b.Lon, 'f', 3, 64)
}

func (s *Service) needFallback(q string, res []Result) bool {
	if len(res) == 0 {
		return true
	}
	if !hasHouseNumber(q) {
		return false
	}
	for _, r := range res {
		if !r.Approximate && r.Type == "house" {
			return false
		}
	}
	return true
}

// ---------- fallback providers ----------

// gate spaces requests at least interval apart across all users; callers
// wait their turn up to a bound, otherwise they are told to try again.
type gate struct {
	mu       sync.Mutex
	interval time.Duration
	next     time.Time
	now      func() time.Time
	sleep    func(ctx context.Context, d time.Duration) error
}

func newGate(interval time.Duration) *gate {
	return &gate{interval: interval, now: time.Now, sleep: func(ctx context.Context, d time.Duration) error {
		t := time.NewTimer(d)
		defer t.Stop()
		select {
		case <-t.C:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
}

func (g *gate) wait(ctx context.Context, max time.Duration) error {
	g.mu.Lock()
	now := g.now()
	start := now
	if g.next.After(now) {
		start = g.next
	}
	d := start.Sub(now)
	if d > max {
		g.mu.Unlock()
		return ErrBusy
	}
	g.next = start.Add(g.interval)
	g.mu.Unlock()
	if d > 0 {
		return g.sleep(ctx, d)
	}
	return nil
}

type fallbacks struct {
	nomBase *url.URL
	nomGate *gate
	client  *http.Client

	censusBase *url.URL
	censusGate *gate
}

// newFallbacks validates the fallback settings with the same SSRF rules as the
// primary provider. An invalid fallback only disables the fallback.
func newFallbacks(s Settings, primary *url.URL, primaryIsNominatim bool) (*fallbacks, error) {
	f := &fallbacks{}
	var firstErr error
	cleartext := false
	if u := strings.TrimSpace(s.FallbackURL); u != "" {
		base, err := parseBaseURL(u, s.AllowPrivate)
		switch {
		case err != nil:
			firstErr = errors.New("fallback: " + err.Error())
		case primaryIsNominatim && strings.EqualFold(base.String(), primary.String()):
			// Same provider as the primary: nothing to fall back to.
		default:
			f.nomBase = base
			f.nomGate = newGate(time.Second)
			cleartext = cleartext || base.Scheme == "http"
		}
	}
	if s.CensusEnabled {
		raw := censusBase
		if s.CensusURL != "" {
			raw = s.CensusURL
		}
		base, err := parseBaseURL(raw, s.AllowPrivate)
		if err != nil {
			if firstErr == nil {
				firstErr = errors.New("census: " + err.Error())
			}
		} else {
			f.censusBase = base
			f.censusGate = newGate(200 * time.Millisecond)
			cleartext = cleartext || base.Scheme == "http"
		}
	}
	if f.nomBase == nil && f.censusBase == nil {
		return nil, firstErr
	}
	f.client = newClient(s.AllowPrivate, cleartext)
	return f, firstErr
}

// fallbackSearch asks Nominatim and then the US Census geocoder. ran reports
// whether any fallback was actually consulted. Fallback failures never fail
// the request on their own; a busy gate is reported only when nothing was found.
func (s *Service) fallbackSearch(ctx context.Context, user, q string, b *Point, limit int) (res []Result, cached, ran bool, err error) {
	f := s.fb
	p := parse(q)
	number := hasHouseNumber(q)
	cached = true
	haveHouse := false
	var busy bool

	run := func(name string, g *gate, target string, parse func([]byte) ([]Result, error), post func([]Result) []Result) {
		key := "f:" + name + ":" + strconv.Itoa(limit) + ":" + NormalizeQuery(target) + biasKey(b)
		if v, ok := s.cache.get(user, key); ok {
			ran = true
			res = append(res, v.([]Result)...)
			return
		}
		if werr := g.wait(ctx, fallbackMaxWait); werr != nil {
			if errors.Is(werr, ErrBusy) {
				busy = true
			}
			return
		}
		ran, cached = true, false
		body, gerr := doGet(ctx, f.client, s.userAgent, target)
		if gerr != nil {
			return
		}
		r, perr := parse(body)
		if perr != nil {
			return
		}
		if post != nil {
			r = post(r)
		}
		if len(r) > limit {
			r = r[:limit]
		}
		s.cache.put(user, key, r, searchTTL)
		res = append(res, r...)
	}

	if f.nomBase != nil {
		nom := nominatim{}
		target := ""
		if len(p.parts) >= 3 && number {
			target = nom.structuredURL(f.nomBase, p.parts[0], p.parts[1], p.parts[len(p.parts)-1], p.usState != "", b, limit, s.lang)
		} else {
			target = nom.searchURL(f.nomBase, strings.Join(p.parts, ", "), b, limit, s.lang)
		}
		run("nominatim", f.nomGate, target, nom.parseSearch, func(r []Result) []Result {
			for i := range r {
				r[i].Source = "nominatim"
				if number && r[i].Type != "house" {
					r[i].Approximate = true
					r[i].Matched = "street"
					if r[i].Type == "city" {
						r[i].Matched = "locality"
					}
				}
			}
			return r
		})
		for _, r := range res {
			if !r.Approximate && r.Type == "house" {
				haveHouse = true
			}
		}
	}
	if f.censusBase != nil && number && !haveHouse && (p.usState != "" || looksUS(b)) {
		c := census{}
		run("census", f.censusGate, c.searchURL(f.censusBase, strings.Join(p.parts, ", ")), c.parse, nil)
	}
	if len(res) == 0 && busy {
		err = ErrBusy
	}
	return res, cached, ran, err
}

// looksUS is a coarse bounding box around the US (including Alaska, Hawaii).
func looksUS(b *Point) bool {
	if b == nil {
		return false
	}
	return b.Lat >= 17 && b.Lat <= 72 && b.Lon >= -180 && b.Lon <= -65
}
