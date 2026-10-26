package handlers

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Watch / live boost. A viewer who has a member's pin open calls
// POST /locations/watch every ~15 s. While at least one watch is live the
// target is "boosted": their device is told (once, no coordinates) to report
// every 1-2 s, and POST /locations echoes "live": true. See docs/live-tracking.md.
const (
	// liveWatchTTL is how long one watch call keeps the boost alive.
	liveWatchTTL = 45 * time.Second
	// liveBoostCommandTTL is the ttl_s carried by the pushed command.
	liveBoostCommandTTL = 60 * time.Second
	// liveBoostMinInterval coalesces commands: at most one per target in this
	// window no matter how many viewers watch.
	liveBoostMinInterval = 30 * time.Second
	// liveBoostRefreshAfter re-sends the command while a watch persists, a
	// little before the previous command's ttl lapses.
	liveBoostRefreshAfter = 45 * time.Second

	watchPerWindow = 30
	watchWindow    = time.Minute
)

// liveWatchRegistry is deliberately in-memory: it is a battery/latency hint,
// not authorization state (every watch call is authorized when made). A
// restart just ends boosts.
type liveWatchRegistry struct {
	mu       sync.Mutex
	watchers map[string]map[string]time.Time // target -> viewer -> expiry
	lastCmd  map[string]time.Time            // target -> last command time
}

func newLiveWatchRegistry() *liveWatchRegistry {
	return &liveWatchRegistry{
		watchers: map[string]map[string]time.Time{},
		lastCmd:  map[string]time.Time{},
	}
}

// touch records/renews viewer watching target and reports whether a live_boost
// command should be sent now (boost newly started or lapsed, or the previous
// command is about to expire) subject to the coalescing interval.
func (g *liveWatchRegistry) touch(viewer, target string, now time.Time) (sendCommand bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	m := g.watchers[target]
	if m == nil {
		m = map[string]time.Time{}
		g.watchers[target] = m
	}
	wasLive := false
	for v, exp := range m {
		if exp.After(now) {
			wasLive = true
		} else {
			delete(m, v)
		}
	}
	m[viewer] = now.Add(liveWatchTTL)

	last, hadCmd := g.lastCmd[target]
	age := now.Sub(last)
	switch {
	case !hadCmd, !wasLive:
		sendCommand = !hadCmd || age >= liveBoostMinInterval
	default:
		sendCommand = age >= liveBoostRefreshAfter
	}
	if sendCommand {
		g.lastCmd[target] = now
	}
	if len(g.watchers) > 1024 {
		for t, mm := range g.watchers {
			alive := false
			for _, exp := range mm {
				if exp.After(now) {
					alive = true
					break
				}
			}
			if !alive {
				delete(g.watchers, t)
				if l, ok := g.lastCmd[t]; ok && now.Sub(l) >= liveBoostMinInterval {
					delete(g.lastCmd, t)
				}
			}
		}
	}
	return sendCommand
}

// boosted reports whether anyone is currently watching target.
func (g *liveWatchRegistry) boosted(target string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, exp := range g.watchers[target] {
		if exp.After(now) {
			return true
		}
	}
	return false
}

// liveBoosted is the hot-path check used by POST /locations.
func (s *Server) liveBoosted(userID string) bool {
	if s.liveWatch == nil {
		return false
	}
	return s.liveWatch.boosted(userID, time.Now())
}

type liveBoostCommand struct {
	Type string `json:"type"`
	TTLS int    `json:"ttl_s"`
}

// WatchMember records that the caller is actively looking at a member's live
// position. Authorization is the same as reading that member's location:
// shared circle + the member shares in it (SharedWith). Anything else is a
// uniform 404 so membership is not probeable. Self-watch is a no-op.
func (s *Server) WatchMember(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if s.LocationLimit != nil && !s.LocationLimit.Allow("locwatch:"+claims.UserID, watchPerWindow, watchWindow) {
		writeError(w, http.StatusTooManyRequests, "too many watch requests")
		return
	}
	var req struct {
		UserID   string `json:"user_id"`
		CircleID string `json:"circle_id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	target := strings.TrimSpace(req.UserID)
	if target == "" {
		writeError(w, http.StatusBadRequest, "user_id is required")
		return
	}
	if target == claims.UserID {
		writeJSON(w, http.StatusOK, map[string]any{"status": "self", "boost": false})
		return
	}

	shared, err := circles.New(s.Pool).SharedWith(r.Context(), claims.UserID, target)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to authorize watch")
		return
	}
	ok := len(shared) > 0
	if ok && req.CircleID != "" {
		ok = false
		for _, c := range shared {
			if strings.EqualFold(c, req.CircleID) {
				ok = true
				break
			}
		}
	}
	if !ok {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}

	reg := s.liveWatch
	if reg == nil {
		reg = newLiveWatchRegistry()
		s.liveWatch = reg
	}
	if reg.touch(claims.UserID, target, time.Now()) {
		body, _ := json.Marshal(liveBoostCommand{Type: "live_boost", TTLS: int(liveBoostCommandTTL / time.Second)})
		send := s.liveBoostSend
		if send == nil {
			send = func(ctx context.Context, userID string, body []byte) bool {
				return s.dispatchSilentCommand(ctx, "OpenFamily live", body, userID)
			}
		}
		postCommitRunner.Submit(func() {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			if !send(ctx, target, body) {
				slog.Debug("live boost: no reachable device", "user_id", target)
			}
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "watching",
		"ttl_s":  int(liveWatchTTL / time.Second),
		"boost":  true,
	})
}
