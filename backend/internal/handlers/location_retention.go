package handlers

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Location history retention (#18). The deployment sets the ceiling
// (LOCATION_RETENTION_DAYS, applied as a TimescaleDB retention policy on the
// locations hypertable at startup). Each user may choose a shorter personal
// window (users.location_retention_days), enforced by RunUserRetention, and may
// erase their own history at any time. Export of one's own data is GET
// /me/export. A user's trail belongs to the person, not to a circle, so the
// personal window applies to every circle they are in.

// userRetentionInterval is how often personal retention windows are enforced.
const userRetentionInterval = time.Hour

type retentionOut struct {
	Days    *int `json:"days"`     // personal window; null = deployment default
	MaxDays int  `json:"max_days"` // deployment ceiling
}

// GetLocationRetention returns the caller's personal window and the ceiling.
func (s *Server) GetLocationRetention(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var days *int
	if err := s.Pool.QueryRow(r.Context(),
		`SELECT location_retention_days FROM users WHERE id = $1`, claims.UserID).Scan(&days); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load retention")
		return
	}
	writeJSON(w, http.StatusOK, retentionOut{Days: days, MaxDays: config.LocationRetentionDays()})
}

// PutLocationRetention sets (days 1..max) or clears (days null) the personal
// window and applies it immediately.
func (s *Server) PutLocationRetention(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var in struct {
		Days *int `json:"days"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	maxDays := config.LocationRetentionDays()
	if in.Days != nil && (*in.Days < 1 || *in.Days > maxDays) {
		writeError(w, http.StatusBadRequest, "days must be between 1 and the server limit")
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE users SET location_retention_days = $2, updated_at = now() WHERE id = $1`,
		claims.UserID, in.Days); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save retention")
		return
	}
	if in.Days != nil {
		if _, err := s.purgeUserLocations(r.Context(), claims.UserID, time.Now().AddDate(0, 0, -*in.Days)); err != nil {
			slog.Warn("retention: immediate purge failed", "user_id", claims.UserID, "err", err)
		}
	}
	s.logAudit(r.Context(), claims.UserID, "", "location.retention_set", retentionDetail(in.Days), clientIP(r))
	writeJSON(w, http.StatusOK, retentionOut{Days: in.Days, MaxDays: maxDays})
}

func retentionDetail(d *int) string {
	if d == nil {
		return "default"
	}
	return strconv.Itoa(*d) + " days"
}

// DeleteMyLocations erases the caller's stored location history: everything, or
// only points older than ?before=RFC3339. Erasing everything also clears the
// last known position, so the person disappears from circles until they next
// report. Deleted rows are removed from the hypertable (not soft-deleted).
func (s *Server) DeleteMyLocations(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	before := time.Now().Add(time.Hour) // everything
	all := true
	if q := r.URL.Query().Get("before"); q != "" {
		t, err := parseRFC3339(q)
		if err != nil {
			writeError(w, http.StatusBadRequest, "before must be RFC3339")
			return
		}
		before, all = t, false
	}
	n, err := s.purgeUserLocations(r.Context(), claims.UserID, before)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete history")
		return
	}
	if all {
		if _, err := s.Pool.Exec(r.Context(), `DELETE FROM member_positions WHERE user_id = $1`, claims.UserID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to clear last position")
			return
		}
	}
	s.logAudit(r.Context(), claims.UserID, "", "location.history_deleted", "own history", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"deleted": n})
}

// purgeUserLocations deletes a user's location rows older than cutoff.
func (s *Server) purgeUserLocations(ctx context.Context, userID string, cutoff time.Time) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `
		DELETE FROM locations l USING devices d
		WHERE d.id = l.device_id AND d.user_id = $1 AND l.ts < $2`, userID, cutoff)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// PurgeUserRetention enforces every personal window once. It returns the
// number of rows deleted.
func (s *Server) PurgeUserRetention(ctx context.Context) (int64, error) {
	rows, err := s.Pool.Query(ctx,
		`SELECT id::text, location_retention_days FROM users WHERE location_retention_days IS NOT NULL`)
	if err != nil {
		return 0, err
	}
	type row struct {
		id   string
		days int
	}
	var users []row
	for rows.Next() {
		var u row
		if err := rows.Scan(&u.id, &u.days); err != nil {
			rows.Close()
			return 0, err
		}
		users = append(users, u)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	var total int64
	for _, u := range users {
		n, err := s.purgeUserLocations(ctx, u.id, time.Now().AddDate(0, 0, -u.days))
		if err != nil {
			return total, err
		}
		total += n
	}
	return total, nil
}

// RunUserRetention enforces personal retention windows until ctx is cancelled.
func (s *Server) RunUserRetention(ctx context.Context) {
	t := time.NewTicker(userRetentionInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n, err := s.PurgeUserRetention(ctx); err != nil {
				slog.Warn("user retention purge", "err", err)
			} else if n > 0 {
				slog.Info("user retention purge", "deleted", n)
			}
		}
	}
}
