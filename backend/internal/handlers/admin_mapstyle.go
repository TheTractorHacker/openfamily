package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"syscall"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// The operator can set the vector map style URL from the admin panel. The
// value lives in app_theme_settings.map_style_url and overrides the
// MAP_STYLE_URL environment variable; GET /config reads it on every request so
// the web and app maps pick it up without a restart.

const maxMapStyleURLLen = 500

// validateMapStyleURL accepts an empty string (clear the override) or a plain
// https URL to a public host: no credentials, no fragment, no IP literal in a
// private range, no localhost.
func validateMapStyleURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if len(raw) > maxMapStyleURLLen {
		return "", errors.New("URL is too long")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "", errors.New("enter a full URL such as https://tiles.example.com/styles/liberty")
	}
	if u.Scheme != "https" {
		return "", errors.New("the style URL must use https")
	}
	if u.User != nil {
		return "", errors.New("the style URL must not contain credentials")
	}
	if u.Fragment != "" {
		return "", errors.New("the style URL must not contain a fragment")
	}
	host := strings.ToLower(u.Hostname())
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") ||
		strings.HasSuffix(host, ".internal") {
		return "", errors.New("the style URL must point at a public host")
	}
	if ip, err := netip.ParseAddr(host); err == nil && internalAddr(ip) {
		return "", errors.New("the style URL must point at a public host")
	}
	return raw, nil
}

func internalAddr(a netip.Addr) bool {
	a = a.Unmap()
	return a.IsLoopback() || a.IsPrivate() || a.IsLinkLocalUnicast() || a.IsLinkLocalMulticast() ||
		a.IsMulticast() || a.IsUnspecified() ||
		netip.MustParsePrefix("100.64.0.0/10").Contains(a) || netip.MustParsePrefix("198.18.0.0/15").Contains(a)
}

// mapStyleOverride returns the admin-set style URL, or "" when none is set.
func (s *Server) mapStyleOverride(ctx context.Context) string {
	if s.Pool == nil {
		return ""
	}
	var v string
	if err := s.Pool.QueryRow(ctx, `SELECT map_style_url FROM app_theme_settings WHERE id = 1`).Scan(&v); err != nil {
		return ""
	}
	if v, err := validateMapStyleURL(v); err == nil {
		return v
	}
	return ""
}

// effectiveMapStyleURL is the admin-set style, else the MAP_STYLE_URL env value.
func (s *Server) effectiveMapStyleURL(ctx context.Context) string {
	if v := s.mapStyleOverride(ctx); v != "" {
		return v
	}
	return s.MapStyleURL
}

func (s *Server) mapStyleJSON(ctx context.Context) map[string]string {
	return map[string]string{
		"map_style_url": s.mapStyleOverride(ctx),
		"env_default":   s.MapStyleURL,
		"effective":     s.effectiveMapStyleURL(ctx),
	}
}

// AdminGetMapStyle returns the admin-set style, the environment default and
// the effective value.
// GET /api/admin/settings/map-style
func (s *Server) AdminGetMapStyle(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.mapStyleJSON(r.Context()))
}

// AdminPutMapStyle sets (or, with an empty value, clears) the style URL.
// PUT /api/admin/settings/map-style
func (s *Server) AdminPutMapStyle(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		MapStyleURL string `json:"map_style_url"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<11)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	v, err := validateMapStyleURL(req.MapStyleURL)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE app_theme_settings SET map_style_url = $1, updated_at = now() WHERE id = 1`, v); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save map style")
		return
	}
	if s.OnMapStyleChange != nil {
		s.OnMapStyleChange(s.effectiveMapStyleURL(r.Context()))
	}
	detail := "set the map style URL"
	if v == "" {
		detail = "cleared the map style URL"
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.map_style_changed", detail, clientIP(r))
	writeJSON(w, http.StatusOK, s.mapStyleJSON(r.Context()))
}

// mapStyleClient refuses to connect to non-public addresses (checked after DNS
// resolution, so rebinding cannot slip past) and to follow redirects.
func mapStyleClient() *http.Client {
	d := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return errors.New("refused")
			}
			ip, err := netip.ParseAddr(host)
			if err != nil || internalAddr(ip) {
				return errors.New("refused: non-public address")
			}
			return nil
		},
	}
	return &http.Client{
		Timeout:       8 * time.Second,
		Transport:     &http.Transport{DialContext: d.DialContext, Proxy: nil},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// checkMapStyle fetches u and verifies it looks like a MapLibre style JSON.
func checkMapStyle(ctx context.Context, c *http.Client, u string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return errors.New("invalid URL")
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		return errors.New("could not reach the style URL")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the style URL answered HTTP %d", resp.StatusCode)
	}
	var st struct {
		Version int               `json:"version"`
		Sources map[string]any    `json:"sources"`
		Layers  []json.RawMessage `json:"layers"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&st); err != nil {
		return errors.New("the response is not valid JSON")
	}
	if st.Version != 8 || len(st.Layers) == 0 {
		return errors.New("the response is not a MapLibre style (expected version 8 with layers)")
	}
	return nil
}

// AdminTestMapStyle checks a style URL (the request body's "map_style_url", or
// the effective one when omitted) without saving it.
// POST /api/admin/settings/map-style/test
func (s *Server) AdminTestMapStyle(w http.ResponseWriter, r *http.Request) {
	var req struct {
		MapStyleURL string `json:"map_style_url"`
	}
	if r.ContentLength != 0 {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<11)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON")
			return
		}
	}
	target := strings.TrimSpace(req.MapStyleURL)
	if target == "" {
		target = s.effectiveMapStyleURL(r.Context())
	}
	if target == "" {
		target = "https://tiles.openfreemap.org/styles/liberty"
	}
	v, err := validateMapStyleURL(target)
	if err != nil || v == "" {
		msg := "invalid URL"
		if err != nil {
			msg = err.Error()
		}
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := checkMapStyle(ctx, mapStyleClient(), v); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// EffectiveMapStyleURL is the exported form of effectiveMapStyleURL, used at
// startup to seed the admin panel CSP.
func (s *Server) EffectiveMapStyleURL(ctx context.Context) string { return s.effectiveMapStyleURL(ctx) }
