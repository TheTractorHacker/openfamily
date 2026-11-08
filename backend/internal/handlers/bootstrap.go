package handlers

import (
	"encoding/json"
	"net/http"
	"net/url"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// memRecorder is a minimal in-memory http.ResponseWriter used to run an
// existing handler inside another one (bootstrap), so authorization stays in
// exactly one place.
type memRecorder struct {
	h    http.Header
	code int
	body []byte
}

func (m *memRecorder) Header() http.Header { return m.h }
func (m *memRecorder) WriteHeader(c int) {
	if m.code == 0 {
		m.code = c
	}
}
func (m *memRecorder) Write(p []byte) (int, error) {
	if m.code == 0 {
		m.code = http.StatusOK
	}
	m.body = append(m.body, p...)
	return len(p), nil
}

// runInternalGet runs a GET handler with the caller's identity and the given
// query string and returns its JSON body, or the failing status.
func runInternalGet(r *http.Request, h http.HandlerFunc, query url.Values) (json.RawMessage, int) {
	req := r.Clone(r.Context())
	req.Method = http.MethodGet
	u := *r.URL
	u.RawQuery = query.Encode()
	req.URL = &u
	req.Header = r.Header.Clone()
	req.Header.Del("If-None-Match")
	rec := &memRecorder{h: http.Header{}}
	h(rec, req)
	if rec.code == 0 {
		rec.code = http.StatusOK
	}
	if rec.code != http.StatusOK {
		return nil, rec.code
	}
	return json.RawMessage(rec.body), rec.code
}

// Bootstrap answers GET /app/bootstrap: everything a phone needs to paint its
// first screen in one round trip (circles, people with their latest positions,
// unread chat counts, compatibility and the server's wire features). It runs
// the same handlers as the individual endpoints, so what a caller may see is
// decided in one place. A section that fails (for example members when the
// caller has no circle yet) is null with its HTTP status in "errors".
// The response is ETag'd by the router, so an unchanged start costs a 304.
//
// ?view=full returns full member records instead of the compact view.
func (s *Server) Bootstrap(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	errs := map[string]int{}
	section := func(name string, h http.HandlerFunc, q url.Values) json.RawMessage {
		body, code := runInternalGet(r, h, q)
		if code != http.StatusOK {
			errs[name] = code
			return nil
		}
		return body
	}
	mq := url.Values{"circle_id": {"all"}, "since": {"bootstrap"}}
	if r.URL.Query().Get("view") != "full" {
		mq.Set("view", "compact")
	}
	circlesJSON := section("circles", s.ListCircles, url.Values{})
	membersJSON := section("members", s.ListMembers, mq)
	unreadJSON := section("unread", s.ChatUnread, url.Values{})

	info := s.CompatPolicy(r.Context()).Describe(
		middleware.AppInfoFromContext(r.Context()).Version, middleware.AppInfoFromContext(r.Context()).Known)
	writeJSON(w, http.StatusOK, map[string]any{
		"server_time":    time.Now().UTC().Format(time.RFC3339Nano),
		"server_version": s.BuildVersion,
		"compat":         info,
		"features":       compat.Features,
		"wire":           s.wireFlags(),
		"circles":        circlesJSON,
		"members":        membersJSON,
		"unread":         unreadJSON,
		"errors":         errs,
	})
}

// wireFlags tells a phone which optional wire features this server has.
func (s *Server) wireFlags() map[string]any {
	return map[string]any{
		"etag":             true,
		"gzip":             true,
		"delta":            []string{"members", "places"},
		"fields":           []string{"members", "places"},
		"history_simplify": true,
		"audit_paging":     true,
		"bootstrap":        true,
		"query":            s.QueryMethod,
	}
}
