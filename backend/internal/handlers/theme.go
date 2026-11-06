package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
)

var accentHexRe = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

// EnsureThemeSchema creates the single-row table that holds the operator's
// default accent color. Idempotent; run at startup.
func (s *Server) EnsureThemeSchema(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS app_theme_settings (
			id           SMALLINT PRIMARY KEY CHECK (id = 1),
			default_accent TEXT NOT NULL DEFAULT '',
			updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
		);
		INSERT INTO app_theme_settings (id) VALUES (1) ON CONFLICT DO NOTHING;`)
	if err != nil {
		return err
	}
	// Instance default for distance/speed units (people can override it).
	if _, err = s.Pool.Exec(ctx, `ALTER TABLE app_theme_settings ADD COLUMN IF NOT EXISTS default_units TEXT NOT NULL DEFAULT 'imperial'`); err != nil {
		return err
	}
	// Admin-set vector map style URL (overrides MAP_STYLE_URL; see admin_mapstyle.go).
	_, err = s.Pool.Exec(ctx, `ALTER TABLE app_theme_settings ADD COLUMN IF NOT EXISTS map_style_url TEXT NOT NULL DEFAULT ''`)
	return err
}

// defaultUnits is the operator's unit system, "imperial" unless set to
// "metric". Errors read as imperial.
func (s *Server) defaultUnits(ctx context.Context) string {
	if s.Pool == nil {
		return "imperial"
	}
	var u string
	if err := s.Pool.QueryRow(ctx, `SELECT default_units FROM app_theme_settings WHERE id = 1`).Scan(&u); err != nil || u != "metric" {
		return "imperial"
	}
	return u
}

// unitsFor resolves a recipient's unit system: their own choice, else the
// instance default.
func (s *Server) unitsFor(ctx context.Context, userID string) string {
	var u string
	if err := s.Pool.QueryRow(ctx, `SELECT units FROM notification_prefs WHERE user_id = $1`, userID).Scan(&u); err == nil && (u == "imperial" || u == "metric") {
		return u
	}
	return s.defaultUnits(ctx)
}

// defaultAccent returns the operator's accent as "#RRGGBB", or "" for the
// built-in green. Errors read as "not set": the theme must never break /config.
func (s *Server) defaultAccent(ctx context.Context) string {
	if s.Pool == nil {
		return ""
	}
	var a string
	if err := s.Pool.QueryRow(ctx,
		`SELECT default_accent FROM app_theme_settings WHERE id = 1`).Scan(&a); err != nil {
		return ""
	}
	if !accentHexRe.MatchString(a) {
		return ""
	}
	return strings.ToUpper(a)
}

// AdminGetTheme returns the operator's default accent color.
func (s *Server) AdminGetTheme(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"default_accent": s.defaultAccent(r.Context()), "default_units": s.defaultUnits(r.Context())})
}

// AdminPutTheme sets (or, with an empty value, clears) the default accent.
func (s *Server) AdminPutTheme(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DefaultAccent *string `json:"default_accent"`
		DefaultUnits  *string `json:"default_units"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	a := s.defaultAccent(r.Context())
	if req.DefaultAccent != nil {
		a = strings.TrimSpace(*req.DefaultAccent)
	}
	if a != "" && !accentHexRe.MatchString(a) {
		writeError(w, http.StatusBadRequest, "color must look like #8FD400")
		return
	}
	a = strings.ToUpper(a)
	if req.DefaultUnits != nil {
		if *req.DefaultUnits != "imperial" && *req.DefaultUnits != "metric" {
			writeError(w, http.StatusBadRequest, "default_units must be imperial or metric")
			return
		}
		if _, err := s.Pool.Exec(r.Context(),
			`UPDATE app_theme_settings SET default_units = $1, updated_at = now() WHERE id = 1`, *req.DefaultUnits); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save units")
			return
		}
	}
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE app_theme_settings SET default_accent = $1, updated_at = now() WHERE id = 1`, a); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save theme")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"default_accent": a, "default_units": s.defaultUnits(r.Context())})
}
