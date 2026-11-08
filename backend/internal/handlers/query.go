package handlers

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// QueryMethod is the HTTP method name from the IETF HTTPBIS "QUERY" draft:
// a safe, idempotent request that carries its parameters in a body.
const QueryMethod = "QUERY"

// queryMaxWindows bounds one batch request.
const queryMaxWindows = 8

type historyQueryReq struct {
	MemberID string `json:"member_id"`
	Windows  []struct {
		From string `json:"from"`
		To   string `json:"to"`
	} `json:"windows"`
	Simplify  float64 `json:"simplify"`
	MaxPoints int     `json:"max_points"`
}

// HistoryQuery returns one member's history for several time windows in one
// round trip: POST or QUERY /family/history/query. It is a read; the same
// handler serves both methods so a client can fall back from QUERY to POST
// without any server difference. Each window obeys the same rules as
// GET /family/members/{id}/history (circle sharing, 25 h and retention
// limits); a window that is refused is reported per window instead of
// failing the others.
//
// When the operator has not enabled the QUERY method (QUERY_METHOD=1) a
// QUERY request answers 405 with Allow: POST and the client falls back.
func (s *Server) HistoryQuery(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Accept-Query", `"application/json"`)
	if r.Method == QueryMethod && !s.QueryMethod {
		w.Header().Set("Allow", "POST, OPTIONS")
		writeError(w, http.StatusMethodNotAllowed, "QUERY is not enabled on this server; use POST")
		return
	}
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if ct := r.Header.Get("Content-Type"); ct != "" && !strings.HasPrefix(strings.ToLower(ct), "application/json") {
		writeError(w, http.StatusUnsupportedMediaType, "send application/json")
		return
	}
	var req historyQueryReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	if req.MemberID == "" || len(req.Windows) == 0 || len(req.Windows) > queryMaxWindows {
		writeError(w, http.StatusBadRequest, "member_id and 1-8 windows are required")
		return
	}
	if req.Simplify < 0 || req.Simplify > maxSimplifyMeters || (req.MaxPoints != 0 && (req.MaxPoints < minTrailMaxPoints || req.MaxPoints > trailPointCap)) {
		writeError(w, http.StatusBadRequest, "simplify must be 0-500 metres and max_points 10-1500")
		return
	}
	type result struct {
		Status  int         `json:"status"`
		Error   string      `json:"error,omitempty"`
		History *historyOut `json:"history,omitempty"`
	}
	results := make([]result, 0, len(req.Windows))
	now := time.Now()
	for _, win := range req.Windows {
		fr := &http.Request{URL: r.URL}
		q := fr.URL.Query()
		q.Set("from", win.From)
		q.Set("to", win.To)
		u := *r.URL
		u.RawQuery = q.Encode()
		fr.URL = &u
		from, to, msg, ok := parseHistoryRange(fr, now)
		if !ok {
			results = append(results, result{Status: http.StatusBadRequest, Error: msg})
			continue
		}
		out, status, emsg := s.memberHistoryForViewer(r.Context(), claims.UserID, req.MemberID, from, to)
		if status != http.StatusOK {
			results = append(results, result{Status: status, Error: emsg})
			continue
		}
		out.Trail = thinTrail(out.Trail, req.MaxPoints, req.Simplify)
		results = append(results, result{Status: http.StatusOK, History: &out})
	}
	writeJSON(w, http.StatusOK, map[string]any{"member_id": req.MemberID, "results": results})
}
