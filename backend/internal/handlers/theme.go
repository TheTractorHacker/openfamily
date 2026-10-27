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
	return err
}

// defaultAccent returns the operator's accent as "#RRGGBB", or "" for the
// built-in green. Errors read as "not set": the theme must never break /config.
func (s *Server) defaultAccent(ctx context.Context) string {
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
	writeJSON(w, http.StatusOK, map[string]string{"default_accent": s.defaultAccent(r.Context())})
}

// AdminPutTheme sets (or, with an empty value, clears) the default accent.
func (s *Server) AdminPutTheme(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DefaultAccent string `json:"default_accent"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	a := strings.TrimSpace(req.DefaultAccent)
	if a != "" && !accentHexRe.MatchString(a) {
		writeError(w, http.StatusBadRequest, "color must look like #8FD400")
		return
	}
	a = strings.ToUpper(a)
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE app_theme_settings SET default_accent = $1, updated_at = now() WHERE id = 1`, a); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save theme")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"default_accent": a})
}
