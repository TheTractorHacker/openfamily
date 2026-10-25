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
		"sms_configured":     s.SMSEnabled(),
		"tile_url":           tileURL,
		"satellite_tile_url": satelliteURL,
		"map_style_url":      s.MapStyleURL,
	})
}
