package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// App compatibility (docs/api-compat.md): the supported-version policy, the
// public GET /compat probe, per-version response shims, and the admin API.

const compatCacheTTL = 15 * time.Second

type compatSettings struct {
	Override string
	Enforce  bool
}

type compatCache struct {
	mu      sync.Mutex
	at      time.Time
	loaded  bool
	current compatSettings
}

// invalidate forces the next read to hit the database (after an admin save).
func (c *compatCache) invalidate() { c.mu.Lock(); c.loaded = false; c.mu.Unlock() }

func (s *Server) compatSettings(ctx context.Context) compatSettings {
	c := &s.compatCache
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.loaded && time.Since(c.at) < compatCacheTTL {
		return c.current
	}
	if s.Pool == nil {
		return compatSettings{}
	}
	var cs compatSettings
	cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := s.Pool.QueryRow(cctx,
		`SELECT min_supported_override, enforce_writes FROM app_compat_settings WHERE id = 1`).Scan(&cs.Override, &cs.Enforce); err != nil {
		// Keep serving the last good value; never fail a request over this.
		if c.loaded {
			return c.current
		}
		return compatSettings{}
	}
	c.current, c.at, c.loaded = cs, time.Now(), true
	return cs
}

// CompatPolicy is the effective policy: admin override, else the env pin,
// else the rolling window of the latest releases.
func (s *Server) CompatPolicy(ctx context.Context) compat.Policy {
	return compat.Compute(s.MinSupportedAppVersion, s.compatSettings(ctx).Override)
}

// CompatEnforceWrites reports whether 426 enforcement is switched on.
func (s *Server) CompatEnforceWrites(ctx context.Context) bool { return s.compatSettings(ctx).Enforce }

// compatSupports reports whether the calling app can use a feature; clients
// that sent no version are assumed capable.
func compatSupports(ctx context.Context, feature string) bool {
	a := middleware.AppInfoFromContext(ctx)
	return compat.Supports(feature, a.Version, a.Known)
}

// applyCircleCompat annotates a circle for the calling app: Private circles
// advertise the app version that can read them, and an app that is too old is
// told so in the circle's name (the one field every app version displays).
func applyCircleCompat(ctx context.Context, c *circleOut) {
	if c.E2EEMode != "private" {
		return
	}
	c.MinAppVersion = compat.Features["private_circles"]
	if !compatSupports(ctx, "private_circles") {
		c.UpdateRequired = true
		c.Name += " (update the app to open this private circle)"
	}
	// A circle whose key log holds processing entries (per-member lanes) cannot be
	// verified by an app below processing_lanes: it must update, not show a blank circle.
	if c.hasLanesLog {
		if v := compat.Features["processing_lanes"]; c.MinAppVersion == "" || compat.MustParse(c.MinAppVersion).Less(compat.MustParse(v)) {
			c.MinAppVersion = v
		}
		if !compatSupports(ctx, "processing_lanes") {
			c.UpdateRequired = true
			if !strings.Contains(c.Name, "(update the app") {
				c.Name += " (update the app to open this private circle)"
			}
		}
	}
}

// refuseUnsupportedApp answers 426 Upgrade Required to an app below the
// supported minimum and returns true, but only when the operator enabled
// enforcement (off by default) and the app reported a version. Clients that
// sent no version are never refused. Called by write endpoints where an
// unsupported client could silently lose or corrupt data.
func (s *Server) refuseUnsupportedApp(w http.ResponseWriter, r *http.Request) bool {
	info := middleware.AppInfoFromContext(r.Context())
	if !info.Known || info.Status != compat.StatusRequired || !s.CompatEnforceWrites(r.Context()) {
		return false
	}
	writeJSON(w, http.StatusUpgradeRequired, map[string]any{
		"error":                 "This version of OpenFamily is no longer supported. Update the app to continue.",
		"code":                  "upgrade_required",
		"upgrade_required":      true,
		"min_supported_version": s.CompatPolicy(r.Context()).Min.String(),
	})
	return true
}

// GetCompat is the lightweight public probe: the caller's status under the
// current policy. The version comes from X-App-Version or ?v=.
func (s *Server) GetCompat(w http.ResponseWriter, r *http.Request) {
	v, ok := compat.Parse(r.Header.Get(middleware.HeaderAppVersion))
	if !ok {
		v, ok = compat.Parse(r.URL.Query().Get("v"))
	}
	info := s.CompatPolicy(r.Context()).Describe(v, ok)
	// Additive: the server's own release and which app version each feature
	// needs, so the app can explain "this needs 0.22" without hard-coding it.
	writeJSON(w, http.StatusOK, struct {
		compat.Info
		ServerVersion string            `json:"server_version,omitempty"`
		Features      map[string]string `json:"features"`
	}{info, s.BuildVersion, compat.Features})
}

// compatInfoFor is the same document for embedding in GET /config.
func (s *Server) compatInfoFor(r *http.Request) compat.Info {
	a := middleware.AppInfoFromContext(r.Context())
	return s.CompatPolicy(r.Context()).Describe(a.Version, a.Known)
}

type adminCompatVersion struct {
	AppVersion string    `json:"app_version"`
	Platform   string    `json:"platform"`
	Users      int       `json:"users"`
	LastSeen   time.Time `json:"last_seen"`
	Status     string    `json:"status"`
}

type adminCompatUser struct {
	UserID     string    `json:"user_id"`
	Name       string    `json:"name"`
	Email      string    `json:"email"`
	AppVersion string    `json:"app_version"`
	Platform   string    `json:"platform"`
	LastSeen   time.Time `json:"last_seen"`
	// Filled for the per-person list on the App versions page.
	Status          string   `json:"status,omitempty"`
	Experience      string   `json:"experience,omitempty"`
	MissingFeatures []string `json:"missing_features,omitempty"`
	UpdateMessage   string   `json:"update_message,omitempty"`
}

// AdminGetCompat reports the policy and which app versions are in use.
func (s *Server) AdminGetCompat(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	cs := s.compatSettings(ctx)
	p := s.CompatPolicy(ctx)

	versions := []adminCompatVersion{}
	rows, err := s.Pool.Query(ctx, `
		SELECT app_version, platform, count(DISTINCT user_id), max(last_seen)
		FROM app_client_versions WHERE last_seen > now() - interval '90 days'
		GROUP BY app_version, platform`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read app versions")
		return
	}
	for rows.Next() {
		var v adminCompatVersion
		if err := rows.Scan(&v.AppVersion, &v.Platform, &v.Users, &v.LastSeen); err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "failed to read app versions")
			return
		}
		pv, ok := compat.Parse(v.AppVersion)
		v.Status = string(p.Classify(pv, ok))
		versions = append(versions, v)
	}
	rows.Close()
	sortVersionsDesc(versions)

	// Every person's most recent app version per platform. People outside the
	// window also go into outside_window (kept for older admin pages).
	outside := []adminCompatUser{}
	people := []adminCompatUser{}
	urows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT ON (a.user_id, a.platform) a.user_id::text, u.name, u.email, a.app_version, a.platform, a.last_seen
		FROM app_client_versions a JOIN users u ON u.id = a.user_id
		WHERE a.last_seen > now() - interval '90 days'
		ORDER BY a.user_id, a.platform, a.last_seen DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read app versions")
		return
	}
	for urows.Next() {
		var u adminCompatUser
		if err := urows.Scan(&u.UserID, &u.Name, &u.Email, &u.AppVersion, &u.Platform, &u.LastSeen); err != nil {
			urows.Close()
			writeError(w, http.StatusInternalServerError, "failed to read app versions")
			return
		}
		pv, pok := compat.Parse(u.AppVersion)
		st := p.Classify(pv, pok)
		u.Status = string(st)
		u.Experience = compat.Experience(st, cs.Enforce)
		if pok {
			u.MissingFeatures = compat.MissingFeatures(pv)
		}
		if st == compat.StatusRequired || st == compat.StatusRecommended {
			u.UpdateMessage = p.UpdateMessage(u.Name)
		}
		people = append(people, u)
	}
	urows.Close()
	sort.SliceStable(people, func(i, j int) bool {
		a, _ := compat.Parse(people[i].AppVersion)
		b, _ := compat.Parse(people[j].AppVersion)
		if c := a.Compare(b); c != 0 {
			return c < 0 // oldest first: the people who need a nudge
		}
		return people[i].Email < people[j].Email
	})
	for _, u := range people {
		if u.Status == string(compat.StatusRequired) {
			outside = append(outside, u)
		}
	}
	if len(outside) > 100 {
		outside = outside[:100]
	}
	if len(people) > 300 {
		people = people[:300]
	}

	var total, withVersion int
	_ = s.Pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&total)
	_ = s.Pool.QueryRow(ctx, `SELECT count(DISTINCT user_id) FROM app_client_versions WHERE last_seen > now() - interval '90 days'`).Scan(&withVersion)

	writeJSON(w, http.StatusOK, map[string]any{
		"policy": map[string]any{
			"min_supported_version": p.Min.String(),
			"latest_version":        p.Latest.String(),
			"window":                p.Window,
			"window_size":           compat.WindowSize,
			"source":                p.Source,
			"env_min_supported":     s.MinSupportedAppVersion,
			"override":              cs.Override,
			"enforce_writes":        cs.Enforce,
		},
		"server": map[string]any{
			"version":  s.BuildVersion,
			"release":  p.Latest.String(),
			"features": compat.Features,
		},
		"experience": map[string]string{
			"ok":          compat.Experience(compat.StatusOK, cs.Enforce),
			"recommended": compat.Experience(compat.StatusRecommended, cs.Enforce),
			"required":    compat.Experience(compat.StatusRequired, cs.Enforce),
			"unknown":     compat.Experience(compat.StatusUnknown, cs.Enforce),
		},
		"versions":           versions,
		"people":             people,
		"outside_window":     outside,
		"users_total":        total,
		"users_with_version": withVersion,
	})
}

func sortVersionsDesc(v []adminCompatVersion) {
	for i := 1; i < len(v); i++ {
		for j := i; j > 0 && compatLess(v[j-1], v[j]); j-- {
			v[j-1], v[j] = v[j], v[j-1]
		}
	}
}

func compatLess(a, b adminCompatVersion) bool {
	av, _ := compat.Parse(a.AppVersion)
	bv, _ := compat.Parse(b.AppVersion)
	if c := av.Compare(bv); c != 0 {
		return c < 0
	}
	return a.Platform > b.Platform
}

// AdminPutCompat sets the minimum-version override ("" clears it) and the
// write-enforcement switch.
func (s *Server) AdminPutCompat(w http.ResponseWriter, r *http.Request) {
	var req struct {
		MinSupportedOverride *string `json:"min_supported_override"`
		EnforceWrites        *bool   `json:"enforce_writes"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	cur := s.compatSettings(r.Context())
	if req.MinSupportedOverride != nil {
		o := strings.TrimSpace(*req.MinSupportedOverride)
		if o != "" {
			v, ok := compat.Parse(o)
			if !ok {
				writeError(w, http.StatusBadRequest, "minimum version must look like 0.16.0")
				return
			}
			o = v.String()
		}
		cur.Override = o
	}
	if req.EnforceWrites != nil {
		cur.Enforce = *req.EnforceWrites
	}
	if _, err := s.Pool.Exec(r.Context(), `
		UPDATE app_compat_settings SET min_supported_override = $1, enforce_writes = $2, updated_at = now() WHERE id = 1`,
		cur.Override, cur.Enforce); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save compatibility settings")
		return
	}
	s.compatCache.invalidate()
	if c := middleware.ClaimsFromContext(r.Context()); c != nil {
		s.logAudit(r.Context(), c.UserID, c.FamilyID, "admin.compat.update",
			"min_supported_override="+cur.Override+" enforce_writes="+map[bool]string{true: "true", false: "false"}[cur.Enforce], clientIP(r))
	}
	s.AdminGetCompat(w, r)
}
