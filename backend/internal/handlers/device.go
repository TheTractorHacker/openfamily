package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

// RegisterDevice registers a new device for the authenticated user.
func (s *Server) RegisterDevice(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	if !s.allowKey(w, "devcreate:user:"+claims.UserID, deviceCreatePerUser, deviceCreateWindow) {
		return
	}

	var req struct {
		Platform            string `json:"platform"`
		Name                string `json:"name"`
		PushToken           string `json:"push_token,omitempty"`
		UnifiedPushEndpoint string `json:"unifiedpush_endpoint,omitempty"`
		AppVersion          string `json:"app_version,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Platform != "ios" && req.Platform != "android" && req.Platform != "web" {
		writeError(w, http.StatusBadRequest, "platform must be ios, android, or web")
		return
	}
	if msg := validateDevicePushFields(req.Platform, req.PushToken, req.UnifiedPushEndpoint); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}

	// Issue a fresh ingest key for the background reporter. Only the SHA-256
	// hash is stored; the plaintext key is returned exactly once, here.
	ingestKey, err := middleware.GenerateDeviceIngestKey()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate device key")
		return
	}

	var device struct {
		ID         string `json:"id"`
		UserID     string `json:"user_id"`
		Platform   string `json:"platform"`
		Name       string `json:"name"`
		AppVersion string `json:"app_version"`
	}
	err = s.Pool.QueryRow(r.Context(), `
		INSERT INTO devices (user_id, platform, name, push_token, unifiedpush_endpoint, app_version, ingest_key_hash, ingest_key_expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id, user_id, platform, name, app_version`,
		claims.UserID, req.Platform, req.Name, req.PushToken, req.UnifiedPushEndpoint, req.AppVersion,
		middleware.EncodeIngestKeyHash(middleware.HashDeviceIngestKey(ingestKey)),
		newIngestKeyExpiry(),
	).Scan(&device.ID, &device.UserID, &device.Platform, &device.Name, &device.AppVersion)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to register device")
		return
	}
	writeJSON(w, http.StatusCreated, struct {
		ID         string `json:"id"`
		UserID     string `json:"user_id"`
		Platform   string `json:"platform"`
		Name       string `json:"name"`
		AppVersion string `json:"app_version"`
		IngestKey  string `json:"ingest_key"`
	}{device.ID, device.UserID, device.Platform, device.Name, device.AppVersion, ingestKey})
}

// RotateDeviceIngestKey issues a fresh ingest key for an existing device
// (`POST /devices/{id}/ingest-key`), invalidating the previous one.
//
// This is how installs that registered before ingest keys existed (their
// devices.ingest_key_hash is NULL) obtain one, and how a suspected-leaked key
// is replaced. The plaintext key is returned exactly once; only its hash is
// stored.
func (s *Server) RotateDeviceIngestKey(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "device id required")
		return
	}

	ingestKey, err := middleware.GenerateDeviceIngestKey()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate device key")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE devices SET ingest_key_hash = $1, ingest_key_expires_at = $4 WHERE id = $2 AND user_id = $3`,
		middleware.EncodeIngestKeyHash(middleware.HashDeviceIngestKey(ingestKey)), id, claims.UserID, newIngestKeyExpiry())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to rotate device key")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"ingest_key": ingestKey})
}

// DeleteDevice removes one of the caller's devices (`DELETE /devices/{id}`).
// Deleting the row revokes its ingest key immediately and, via ON DELETE
// CASCADE, also removes the device's stored location history and push-tracking
// rows. Only the owner can delete; another user's device id is a 404.
func (s *Server) DeleteDevice(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "device id required")
		return
	}
	tag, err := s.Pool.Exec(r.Context(),
		`DELETE FROM devices WHERE id = $1 AND user_id = $2`, id, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete device")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "device.deleted", "deleted device "+id, clientIP(r))
	w.WriteHeader(http.StatusNoContent)
}

// UpdateDevice attaches or clears push credentials on an existing device.
// Empty strings clear the corresponding column; omitted fields are left as-is.
func (s *Server) UpdateDevice(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "device id required")
		return
	}

	var req struct {
		PushToken           *string `json:"push_token"`
		UnifiedPushEndpoint *string `json:"unifiedpush_endpoint"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.PushToken == nil && req.UnifiedPushEndpoint == nil {
		writeError(w, http.StatusBadRequest, "provide push_token or unifiedpush_endpoint")
		return
	}

	var platform string
	var curToken, curEndpoint *string
	err := s.Pool.QueryRow(r.Context(), `
		SELECT platform, push_token, unifiedpush_endpoint
		FROM devices WHERE id = $1 AND user_id = $2`, id, claims.UserID,
	).Scan(&platform, &curToken, &curEndpoint)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load device")
		return
	}

	token := derefOrEmpty(curToken)
	endpoint := derefOrEmpty(curEndpoint)
	if req.PushToken != nil {
		token = strings.TrimSpace(*req.PushToken)
	}
	if req.UnifiedPushEndpoint != nil {
		endpoint = strings.TrimSpace(*req.UnifiedPushEndpoint)
	}
	if msg := validateDevicePushFields(platform, token, endpoint); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}

	_, err = s.Pool.Exec(r.Context(), `
		UPDATE devices SET push_token = NULLIF($1, ''), unifiedpush_endpoint = NULLIF($2, '')
		WHERE id = $3 AND user_id = $4`,
		token, endpoint, id, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update device")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
}

// ListDevices returns the authenticated user's devices.
func (s *Server) ListDevices(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, user_id, platform, name, last_seen, app_version, created_at
		FROM devices WHERE user_id = $1 ORDER BY created_at`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list devices")
		return
	}
	defer rows.Close()

	type deviceOut struct {
		ID         string     `json:"id"`
		UserID     string     `json:"user_id"`
		Platform   string     `json:"platform"`
		Name       string     `json:"name"`
		LastSeen   *time.Time `json:"last_seen,omitempty"`
		AppVersion string     `json:"app_version"`
		CreatedAt  time.Time  `json:"created_at"`
	}
	devices := []deviceOut{}
	for rows.Next() {
		var d deviceOut
		if err := rows.Scan(&d.ID, &d.UserID, &d.Platform, &d.Name, &d.LastSeen, &d.AppVersion, &d.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan device")
			return
		}
		devices = append(devices, d)
	}
	writeJSON(w, http.StatusOK, devices)
}

// HeartbeatDevice records that an authenticated device is alive without
// reporting a location: `POST /devices/heartbeat` with {"device_id": ...}.
//
// Clients send this while stationary so the family sees fresh "last seen"
// freshness without growing the locations table (the ingest path separately
// dedups stationary points; the heartbeat covers clients whose GPS stream does
// not fire at all when not moving). It only touches devices.last_seen and
// broadcasts a `presence` frame — no location rows are written.
func (s *Server) HeartbeatDevice(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	if !s.allowKey(w, "heartbeat:user:"+claims.UserID, heartbeatPerUser, heartbeatWindow) {
		return
	}

	var req struct {
		DeviceID   string   `json:"device_id"`
		BatteryPct *float64 `json:"battery_pct,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_id is required")
		return
	}

	var ownerID string
	err := s.Pool.QueryRow(r.Context(), `
		SELECT user_id FROM devices WHERE id = $1`, req.DeviceID).Scan(&ownerID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load device")
		return
	}
	if ownerID != claims.UserID {
		writeError(w, http.StatusForbidden, "device does not belong to you")
		return
	}

	if _, err := s.Pool.Exec(r.Context(), `
		UPDATE devices SET last_seen = now() WHERE id = $1 AND user_id = $2`,
		req.DeviceID, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update device")
		return
	}

	// Best-effort liveness fan-out: family members see the member stay fresh
	// without any position change.
	go s.broadcastPresence(claims.UserID, time.Now(), req.BatteryPct)

	w.WriteHeader(http.StatusNoContent)
}

// validateDevicePushFields returns a client-facing error or "" if the
// platform/credential combination is acceptable. Empty credentials are
// allowed (the device simply will not receive pushes).
func validateDevicePushFields(platform, pushToken, unifiedpushEndpoint string) string {
	if platform == "ios" && unifiedpushEndpoint != "" {
		return "ios devices must use push_token, not unifiedpush_endpoint"
	}
	if platform == "android" && pushToken != "" {
		return "android devices must use unifiedpush_endpoint, not push_token"
	}
	if unifiedpushEndpoint != "" {
		if err := push.ValidateUnifiedPushEndpoint(unifiedpushEndpoint); err != nil {
			return "invalid unifiedpush_endpoint"
		}
	}
	return ""
}

func derefOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
