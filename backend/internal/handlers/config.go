package handlers

import (
	"net/http"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
)

// GetConfig returns public runtime settings the generic APK needs without a
// dart-define (ntfy origin, map tile templates, and whether SMS is on).
// Auth is optional.
func (s *Server) GetConfig(w http.ResponseWriter, r *http.Request) {
	tileURL := s.TileURL
	if tileURL == "" {
		tileURL = config.DefaultTileURL
	}
	satelliteURL := s.SatelliteTileURL
	if satelliteURL == "" {
		satelliteURL = config.DefaultSatelliteTileURL
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ntfy_base_url":      s.NtfyBaseURL,
		"apns_configured":    s.APNsConfigured,
		"direct_push":        s.Direct != nil,
		"sms_configured":     s.SMSEnabled(),
		"tile_url":           tileURL,
		"satellite_tile_url": satelliteURL,
		"map_style_url":      s.MapStyleURL,
		// Operator's default accent ("#RRGGBB"), empty for the built-in green.
		"default_accent": s.defaultAccent(r.Context()),
		// Availability only; the provider URL is never exposed.
		"geocoder": map[string]bool{
			"enabled":      s.Geocoder.Enabled(),
			"autocomplete": s.Geocoder.Autocomplete(),
		},
	})
}
