package handlers

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/geocode"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	geocodeSearchPerMin  = 30
	geocodeReversePerMin = 20
	geocodeWindow        = time.Minute
)

// geocodeGate runs the checks shared by both endpoints. It writes the error
// response and returns "" when the request must stop.
func (s *Server) geocodeGate(w http.ResponseWriter, r *http.Request, op string, max int) string {
	if !s.Geocoder.Enabled() {
		writeError(w, http.StatusServiceUnavailable, "geocoding is not configured")
		return ""
	}
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil || claims.UserID == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return ""
	}
	if !s.allowKey(w, "geocode:"+op+":"+claims.UserID, max, geocodeWindow) {
		return ""
	}
	return claims.UserID
}

func parseCoord(raw string, limit float64) (float64, bool) {
	v, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < -limit || v > limit {
		return 0, false
	}
	return v, true
}

// GeocodeSearch proxies forward geocoding / autocomplete.
//
//	GET /geocode/search?q=&lat=&lon=&limit=[&explicit=1]
//
// PRIVACY: neither q nor lat/lon is ever logged; only status, count, cache
// hit and latency are.
func (s *Server) GeocodeSearch(w http.ResponseWriter, r *http.Request) {
	uid := s.geocodeGate(w, r, "search", geocodeSearchPerMin)
	if uid == "" {
		return
	}
	qv := r.URL.Query()
	q := strings.TrimSpace(qv.Get("q"))
	if !geocode.ValidQuery(q) {
		writeError(w, http.StatusBadRequest, "q must be 3 to 120 characters")
		return
	}
	var bias *geocode.Point
	latS, lonS := qv.Get("lat"), qv.Get("lon")
	if latS != "" || lonS != "" {
		lat, ok1 := parseCoord(latS, 90)
		lon, ok2 := parseCoord(lonS, 180)
		if !ok1 || !ok2 {
			writeError(w, http.StatusBadRequest, "lat/lon out of range")
			return
		}
		bias = &geocode.Point{Lat: lat, Lon: lon}
	}
	limit := 5
	if l := qv.Get("limit"); l != "" {
		n, err := strconv.Atoi(l)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "invalid limit")
			return
		}
		limit = min(n, 8)
	}
	// The public OSM Nominatim forbids autocomplete: only an explicit, user
	// submitted search is allowed there.
	if !s.Geocoder.Autocomplete() && qv.Get("explicit") != "1" {
		writeError(w, http.StatusBadRequest, "autocomplete is disabled; submit an explicit search")
		return
	}

	start := time.Now()
	resp, err := s.Geocoder.SearchWith(r.Context(), uid, q, geocode.SearchOptions{
		Bias: bias, Limit: limit, Explicit: qv.Get("explicit") == "1",
	})
	res := resp.Results
	if err != nil {
		s.geocodeFail(w, "search", start, err)
		return
	}
	slog.Info("geocode", "op", "search", "status", http.StatusOK, "results", len(res),
		"attempts", resp.Attempts, "approximate", resp.Approximate, "fallback", resp.Fallback,
		"ms", time.Since(start).Milliseconds())
	if res == nil {
		res = []geocode.Result{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": res, "approximate": resp.Approximate})
}

// GeocodeReverse proxies reverse geocoding: GET /geocode/reverse?lat=&lon=.
func (s *Server) GeocodeReverse(w http.ResponseWriter, r *http.Request) {
	uid := s.geocodeGate(w, r, "reverse", geocodeReversePerMin)
	if uid == "" {
		return
	}
	qv := r.URL.Query()
	lat, ok1 := parseCoord(qv.Get("lat"), 90)
	lon, ok2 := parseCoord(qv.Get("lon"), 180)
	if !ok1 || !ok2 {
		writeError(w, http.StatusBadRequest, "lat/lon required and in range")
		return
	}
	start := time.Now()
	addr, _, err := s.Geocoder.Reverse(r.Context(), uid, geocode.Point{Lat: lat, Lon: lon})
	if err != nil {
		s.geocodeFail(w, "reverse", start, err)
		return
	}
	if addr == nil {
		slog.Info("geocode", "op", "reverse", "status", http.StatusNotFound,
			"ms", time.Since(start).Milliseconds())
		writeError(w, http.StatusNotFound, "no address found")
		return
	}
	slog.Info("geocode", "op", "reverse", "status", http.StatusOK,
		"ms", time.Since(start).Milliseconds())
	writeJSON(w, http.StatusOK, addr)
}

// geocodeFail maps a sanitized provider error to a response and logs only its
// class (never the URL, query or coordinates).
func (s *Server) geocodeFail(w http.ResponseWriter, op string, start time.Time, err error) {
	status := http.StatusBadGateway
	kind := geocode.KindUnavailable
	var ge *geocode.Error
	if errors.As(err, &ge) {
		kind = ge.Kind
	}
	switch kind {
	case geocode.KindBusy:
		status = http.StatusTooManyRequests
		w.Header().Set("Retry-After", "1")
	case geocode.KindTimeout:
		status = http.StatusGatewayTimeout
	}
	if errors.Is(err, context.Canceled) {
		status = 499
	}
	slog.Warn("geocode", "op", op, "status", status, "error", string(kind),
		"ms", time.Since(start).Milliseconds())
	msg := "geocoder unavailable"
	if status == http.StatusTooManyRequests {
		msg = "too many requests"
	}
	writeError(w, status, msg)
}
