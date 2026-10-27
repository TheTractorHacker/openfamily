package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

const (
	dawarichInterval  = time.Minute
	dawarichBatchSize = 500
	dawarichMaxKeyLen = 256
	dawarichHTTPLimit = 20 * time.Second
)

var dawarichClient = &http.Client{Timeout: dawarichHTTPLimit}

type dawarichRow struct {
	BaseURL      string
	LocalURL     string
	APIKey       string
	Enabled      bool
	SendUnmapped bool
	Since        time.Time
	LastSyncAt   *time.Time
	LastError    string
	TotalSent    int64
}

type dawarichResponse struct {
	Enabled      bool       `json:"enabled"`
	BaseURL      string     `json:"base_url"`
	LocalURL     string     `json:"local_url"`
	APIKeySet    bool       `json:"api_key_set"`
	SendUnmapped bool       `json:"send_unmapped"`
	Since        time.Time  `json:"since"`
	LastSyncAt   *time.Time `json:"last_sync_at"`
	LastError    string     `json:"last_error"`
	TotalSent    int64      `json:"total_sent"`
	Pending      int64      `json:"pending"`
}

type dawarichPutRequest struct {
	BaseURL      string `json:"base_url"`
	LocalURL     string `json:"local_url"`
	APIKey       string `json:"api_key"`
	Enabled      bool   `json:"enabled"`
	SendUnmapped bool   `json:"send_unmapped"`
	BackfillDays int    `json:"backfill_days"`
}

// endpoints lists the addresses to try in order: public URL, then LAN.
func (r dawarichRow) endpoints() []string {
	out := []string{r.BaseURL}
	if r.LocalURL != "" && r.LocalURL != r.BaseURL {
		out = append(out, r.LocalURL)
	}
	return out
}

// postPoints sends one batch, falling back to the next address only when an
// address is unreachable (a real HTTP error from Dawarich is not retried).
func (r dawarichRow) postPoints(ctx context.Context, key string, body []byte) error {
	var netErr error
	for _, base := range r.endpoints() {
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
			base+"/api/v1/points?api_key="+url.QueryEscape(key), bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		resp, err := dawarichClient.Do(req)
		if err != nil {
			netErr = fmt.Errorf("could not reach Dawarich at %s: %w", base, err)
			continue
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if resp.StatusCode >= 300 {
			return fmt.Errorf("Dawarich answered %d", resp.StatusCode)
		}
		return nil
	}
	return netErr
}

func (s *Server) readDawarich(ctx context.Context) (dawarichRow, bool, error) {
	var row dawarichRow
	err := s.Pool.QueryRow(ctx, `
		SELECT base_url, local_url, api_key, enabled, send_unmapped, since, last_sync_at, last_error, total_sent
		FROM dawarich_settings WHERE id = 1`).Scan(
		&row.BaseURL, &row.LocalURL, &row.APIKey, &row.Enabled, &row.SendUnmapped, &row.Since, &row.LastSyncAt, &row.LastError, &row.TotalSent)
	if errors.Is(err, pgx.ErrNoRows) {
		return dawarichRow{}, false, nil
	}
	return row, err == nil, err
}

func normalizeDawarichURL(raw string) (string, error) {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return "", errors.New("Dawarich address is required")
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", errors.New("use a full address such as https://dawarich.example.com")
	}
	return raw, nil
}

func (s *Server) dawarichPending(ctx context.Context, row dawarichRow) int64 {
	if row.Since.IsZero() {
		return 0
	}
	var n int64
	_ = s.Pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM locations l
		JOIN devices d ON d.id = l.device_id
		LEFT JOIN dawarich_user_map m ON m.user_id = d.user_id
		LEFT JOIN dawarich_cursor c ON c.device_id = l.device_id
		WHERE l.ts > COALESCE(c.last_ts, COALESCE(m.since, $1))
		  AND ((m.user_id IS NOT NULL AND m.enabled) OR (m.user_id IS NULL AND $2))`,
		row.Since, row.SendUnmapped && row.APIKey != "").Scan(&n)
	return n
}

func (s *Server) dawarichJSON(ctx context.Context, row dawarichRow) dawarichResponse {
	return dawarichResponse{
		Enabled:      row.Enabled,
		BaseURL:      row.BaseURL,
		LocalURL:     row.LocalURL,
		APIKeySet:    row.APIKey != "",
		SendUnmapped: row.SendUnmapped,
		Since:        row.Since,
		LastSyncAt:   row.LastSyncAt,
		LastError:    row.LastError,
		TotalSent:    row.TotalSent,
		Pending:      s.dawarichPending(ctx, row),
	}
}

// AdminGetDawarich returns the sync configuration without the API key.
func (s *Server) AdminGetDawarich(w http.ResponseWriter, r *http.Request) {
	row, _, err := s.readDawarich(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load Dawarich settings")
		return
	}
	writeJSON(w, http.StatusOK, s.dawarichJSON(r.Context(), row))
}

// AdminPutDawarich saves the address, API key and on/off switch.
func (s *Server) AdminPutDawarich(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req dawarichPutRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	base, err := normalizeDawarichURL(req.BaseURL)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	local := ""
	if strings.TrimSpace(req.LocalURL) != "" {
		if local, err = normalizeDawarichURL(req.LocalURL); err != nil {
			writeError(w, http.StatusBadRequest, "local address: "+err.Error())
			return
		}
	}
	key := strings.TrimSpace(req.APIKey)
	if len(key) > dawarichMaxKeyLen {
		writeError(w, http.StatusBadRequest, "API key is too long")
		return
	}
	existing, _, err := s.readDawarich(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load Dawarich settings")
		return
	}
	if key == "" {
		key = existing.APIKey
	}
	if key == "" && req.SendUnmapped {
		writeError(w, http.StatusBadRequest, "add the main API key, or turn off “send everyone else”")
		return
	}
	days := req.BackfillDays
	if days < 0 || days > 90 {
		writeError(w, http.StatusBadRequest, "history to include must be 0–90 days")
		return
	}
	// Sync is add-only and starts from now unless the admin asks for history
	// (backfill_days, applied only when the settings row is first created).
	_, err = s.Pool.Exec(r.Context(), `
		INSERT INTO dawarich_settings (id, base_url, local_url, api_key, enabled, send_unmapped, since, last_error, updated_at)
		VALUES (1, $1, $4, $2, $3, $5, now() - make_interval(days => $6), '', now())
		ON CONFLICT (id) DO UPDATE SET
			base_url = EXCLUDED.base_url, local_url = EXCLUDED.local_url, api_key = EXCLUDED.api_key,
			enabled = EXCLUDED.enabled, send_unmapped = EXCLUDED.send_unmapped, last_error = '', updated_at = now()`,
		base, key, req.Enabled, local, req.SendUnmapped, days)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save Dawarich settings")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "dawarich.settings_updated", "updated Dawarich sync settings", clientIP(r))
	row, _, _ := s.readDawarich(r.Context())
	writeJSON(w, http.StatusOK, s.dawarichJSON(r.Context(), row))
}

// AdminDeleteDawarich disconnects Dawarich and forgets sync progress.
func (s *Server) AdminDeleteDawarich(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `DELETE FROM dawarich_settings WHERE id = 1`); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to clear Dawarich settings")
		return
	}
	_, _ = s.Pool.Exec(r.Context(), `DELETE FROM dawarich_cursor`)
	_, _ = s.Pool.Exec(r.Context(), `DELETE FROM dawarich_user_map`)
	s.logAudit(r.Context(), claims.UserID, "", "dawarich.settings_cleared", "disconnected Dawarich sync", clientIP(r))
	writeJSON(w, http.StatusOK, s.dawarichJSON(r.Context(), dawarichRow{}))
}

// AdminTestDawarich checks the saved address and key against Dawarich.
func (s *Server) AdminTestDawarich(w http.ResponseWriter, r *http.Request) {
	row, ok, err := s.readDawarich(r.Context())
	if err != nil || !ok {
		writeError(w, http.StatusBadRequest, "save the Dawarich settings first")
		return
	}
	var lastErr error
	for _, base := range row.endpoints() {
		req, _ := http.NewRequestWithContext(r.Context(), http.MethodGet, base+"/api/v1/health", nil)
		resp, err := dawarichClient.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("could not reach %s: %w", base, err)
			continue
		}
		resp.Body.Close()
		if resp.StatusCode >= 400 {
			lastErr = fmt.Errorf("%s answered %d", base, resp.StatusCode)
			continue
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "reached": base})
		return
	}
	writeError(w, http.StatusBadGateway, lastErr.Error())
}

// AdminDawarichSyncNow runs one sync pass immediately.
func (s *Server) AdminDawarichSyncNow(w http.ResponseWriter, r *http.Request) {
	row, ok, err := s.readDawarich(r.Context())
	if err != nil || !ok {
		writeError(w, http.StatusBadRequest, "save the Dawarich settings first")
		return
	}
	s.syncDawarichOnce(r.Context(), true)
	row, _, _ = s.readDawarich(r.Context())
	writeJSON(w, http.StatusOK, s.dawarichJSON(r.Context(), row))
}

// RunDawarichSync pushes new location fixes to Dawarich every minute.
func (s *Server) RunDawarichSync(ctx context.Context) {
	ticker := time.NewTicker(dawarichInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.syncDawarichOnce(ctx, false)
		}
	}
}

type dawarichPoint struct {
	deviceID string
	ts       time.Time
	feature  map[string]any
}

// dawarichTarget is one Dawarich account to push to. UserID is empty for the
// main account, which receives everyone who has no mapping of their own.
type dawarichTarget struct {
	UserID string
	Key    string
	Since  time.Time
}

func (s *Server) dawarichTargets(ctx context.Context, row dawarichRow) ([]dawarichTarget, error) {
	var out []dawarichTarget
	if row.SendUnmapped && row.APIKey != "" {
		out = append(out, dawarichTarget{Key: row.APIKey, Since: row.Since})
	}
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text, api_key, since FROM dawarich_user_map WHERE enabled`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var t dawarichTarget
		if err := rows.Scan(&t.UserID, &t.Key, &t.Since); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Server) syncDawarichOnce(ctx context.Context, force bool) {
	row, ok, err := s.readDawarich(ctx)
	if err != nil || !ok || (!row.Enabled && !force) {
		return
	}
	targets, err := s.dawarichTargets(ctx, row)
	if err != nil {
		slog.Warn("dawarich targets", "err", err)
		return
	}
	var total int64
	var firstErr string
	for _, t := range targets {
		sent, perr := s.pushDawarich(ctx, row, t)
		total += sent
		msg := ""
		if perr != nil {
			msg = perr.Error()
			slog.Warn("dawarich sync", "user", t.UserID, "err", perr)
			if firstErr == "" {
				firstErr = msg
			}
		}
		if t.UserID != "" {
			_, _ = s.Pool.Exec(ctx, `
				UPDATE dawarich_user_map SET last_error = $1, total_sent = total_sent + $2
				WHERE user_id = $3`, msg, sent, t.UserID)
		}
	}
	_, _ = s.Pool.Exec(ctx, `
		UPDATE dawarich_settings
		SET last_sync_at = now(), last_error = $1, total_sent = total_sent + $2
		WHERE id = 1`, firstErr, total)
}

func (s *Server) pushDawarich(ctx context.Context, row dawarichRow, t dawarichTarget) (int64, error) {
	var total int64
	for round := 0; round < 20; round++ {
		points, err := s.nextDawarichBatch(ctx, t)
		if err != nil {
			return total, err
		}
		if len(points) == 0 {
			return total, nil
		}
		feats := make([]map[string]any, len(points))
		for i, p := range points {
			feats[i] = p.feature
		}
		body, _ := json.Marshal(map[string]any{"locations": feats})
		if err := row.postPoints(ctx, t.Key, body); err != nil {
			return total, err
		}
		newest := map[string]time.Time{}
		for _, p := range points {
			if p.ts.After(newest[p.deviceID]) {
				newest[p.deviceID] = p.ts
			}
		}
		for dev, ts := range newest {
			if _, err := s.Pool.Exec(ctx, `
				INSERT INTO dawarich_cursor (device_id, last_ts) VALUES ($1, $2)
				ON CONFLICT (device_id) DO UPDATE SET last_ts = GREATEST(dawarich_cursor.last_ts, EXCLUDED.last_ts)`,
				dev, ts); err != nil {
				return total, err
			}
		}
		total += int64(len(points))
		if len(points) < dawarichBatchSize {
			return total, nil
		}
	}
	return total, nil
}

// nextDawarichBatch returns the oldest unsent fixes for one target. Devices
// with no cursor start at the target's since, so nothing older is ever pushed
// unless the admin chose a backfill.
func (s *Server) nextDawarichBatch(ctx context.Context, t dawarichTarget) ([]dawarichPoint, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT l.device_id::text, l.ts, ST_Y(l.geom), ST_X(l.geom),
		       l.accuracy_meters, l.altitude_meters, l.speed_mps, l.battery_pct,
		       u.name
		FROM locations l
		JOIN devices d ON d.id = l.device_id
		JOIN users u ON u.id = d.user_id
		LEFT JOIN dawarich_cursor c ON c.device_id = l.device_id
		WHERE l.ts > COALESCE(c.last_ts, $1)
		  AND CASE WHEN $2::text = '' THEN NOT EXISTS (SELECT 1 FROM dawarich_user_map m WHERE m.user_id = u.id)
		           ELSE u.id::text = $2::text END
		ORDER BY l.ts ASC
		LIMIT $3`, t.Since, t.UserID, dawarichBatchSize)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dawarichPoint
	for rows.Next() {
		var (
			dev, name            string
			ts                   time.Time
			lat, lon             float64
			acc, alt, speed, bat *float64
		)
		if err := rows.Scan(&dev, &ts, &lat, &lon, &acc, &alt, &speed, &bat, &name); err != nil {
			return nil, err
		}
		props := map[string]any{
			"timestamp": ts.UTC().Format(time.RFC3339),
			"device_id": name,
			"unique_id": dev,
		}
		if acc != nil {
			props["horizontal_accuracy"] = *acc
		}
		if alt != nil {
			props["altitude"] = *alt
		}
		if speed != nil {
			props["speed"] = *speed
		}
		if bat != nil {
			props["battery_level"] = *bat / 100
		}
		out = append(out, dawarichPoint{deviceID: dev, ts: ts, feature: map[string]any{
			"type":       "Feature",
			"geometry":   map[string]any{"type": "Point", "coordinates": []float64{lon, lat}},
			"properties": props,
		}})
	}
	return out, rows.Err()
}

// ---- Per-user mapping ----

type dawarichUserOut struct {
	UserID    string     `json:"user_id"`
	Name      string     `json:"name"`
	Email     string     `json:"email"`
	Mapped    bool       `json:"mapped"`
	Label     string     `json:"label"`
	Enabled   bool       `json:"enabled"`
	APIKeySet bool       `json:"api_key_set"`
	Since     *time.Time `json:"since"`
	LastError string     `json:"last_error"`
	TotalSent int64      `json:"total_sent"`
}

type dawarichUserPut struct {
	APIKey       string `json:"api_key"`
	Label        string `json:"label"`
	Enabled      bool   `json:"enabled"`
	BackfillDays int    `json:"backfill_days"`
}

// AdminListDawarichUsers lists every account with its Dawarich mapping.
func (s *Server) AdminListDawarichUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Pool.Query(r.Context(), `
		SELECT u.id::text, u.name, u.email, m.user_id IS NOT NULL, COALESCE(m.label, ''),
		       COALESCE(m.enabled, FALSE), COALESCE(m.api_key, '') <> '', m.since,
		       COALESCE(m.last_error, ''), COALESCE(m.total_sent, 0)
		FROM users u LEFT JOIN dawarich_user_map m ON m.user_id = u.id
		ORDER BY lower(u.name), u.email`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load users")
		return
	}
	defer rows.Close()
	out := []dawarichUserOut{}
	for rows.Next() {
		var u dawarichUserOut
		if err := rows.Scan(&u.UserID, &u.Name, &u.Email, &u.Mapped, &u.Label, &u.Enabled,
			&u.APIKeySet, &u.Since, &u.LastError, &u.TotalSent); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load users")
			return
		}
		out = append(out, u)
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminPutDawarichUser maps one person to their own Dawarich account.
func (s *Server) AdminPutDawarichUser(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := chi.URLParam(r, "id")
	var req dawarichUserPut
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	key := strings.TrimSpace(req.APIKey)
	if len(key) > dawarichMaxKeyLen {
		writeError(w, http.StatusBadRequest, "API key is too long")
		return
	}
	if req.BackfillDays < 0 || req.BackfillDays > 90 {
		writeError(w, http.StatusBadRequest, "history to include must be 0–90 days")
		return
	}
	label := strings.TrimSpace(req.Label)
	if len(label) > 120 {
		writeError(w, http.StatusBadRequest, "label is too long")
		return
	}
	var exists, mapped bool
	if err := s.Pool.QueryRow(r.Context(), `
		SELECT TRUE, EXISTS (SELECT 1 FROM dawarich_user_map WHERE user_id = $1)
		FROM users WHERE id = $1`, userID).Scan(&exists, &mapped); err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	if !mapped && key == "" {
		writeError(w, http.StatusBadRequest, "API key is required")
		return
	}
	if mapped {
		_, err := s.Pool.Exec(r.Context(), `
			UPDATE dawarich_user_map
			SET api_key = CASE WHEN $2 = '' THEN api_key ELSE $2 END,
			    label = $3, enabled = $4, last_error = ''
			WHERE user_id = $1`, userID, key, label, req.Enabled)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save mapping")
			return
		}
	} else {
		if _, err := s.Pool.Exec(r.Context(), `
			INSERT INTO dawarich_user_map (user_id, api_key, label, enabled, since)
			VALUES ($1, $2, $3, $4, now() - make_interval(days => $5))`,
			userID, key, label, req.Enabled, req.BackfillDays); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save mapping")
			return
		}
		// Restart this person's devices at the new account's start point so a
		// previous destination's progress doesn't hide (or replay) their data.
		_, _ = s.Pool.Exec(r.Context(), `
			DELETE FROM dawarich_cursor WHERE device_id IN (SELECT id FROM devices WHERE user_id = $1)`, userID)
	}
	s.logAudit(r.Context(), claims.UserID, "", "dawarich.user_mapped", "mapped a user to a Dawarich account", clientIP(r))
	s.AdminListDawarichUsers(w, r)
}

// AdminDeleteDawarichUser removes a mapping. Nothing is removed from Dawarich.
func (s *Server) AdminDeleteDawarichUser(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `DELETE FROM dawarich_user_map WHERE user_id = $1`, chi.URLParam(r, "id")); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to remove mapping")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "dawarich.user_unmapped", "removed a Dawarich user mapping", clientIP(r))
	s.AdminListDawarichUsers(w, r)
}

// EnsureDawarichSchema adds the per-user mapping objects idempotently. It is
// deliberately not a numbered migration: migration versions are shared with
// other in-flight work and a skipped number would never be applied.
func (s *Server) EnsureDawarichSchema(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `
		ALTER TABLE dawarich_settings
			ADD COLUMN IF NOT EXISTS send_unmapped BOOLEAN NOT NULL DEFAULT FALSE,
			ADD COLUMN IF NOT EXISTS since TIMESTAMPTZ NOT NULL DEFAULT now();
		CREATE TABLE IF NOT EXISTS dawarich_user_map (
			user_id    UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
			api_key    TEXT NOT NULL,
			label      TEXT NOT NULL DEFAULT '',
			enabled    BOOLEAN NOT NULL DEFAULT TRUE,
			since      TIMESTAMPTZ NOT NULL DEFAULT now(),
			last_error TEXT NOT NULL DEFAULT '',
			total_sent BIGINT NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`)
	return err
}
