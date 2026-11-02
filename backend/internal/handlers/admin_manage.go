package handlers

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Platform-admin management of share links and circles. Read-mostly: the admin
// sees every account's links and every circle (including temporary ones that
// lapsed but are not purged yet), and can revoke a link, revoke an invite, or
// end/extend a temporary circle. Never exposes tokens (only a hash is stored).

type adminShareLinkOut struct {
	ID        string     `json:"id"`
	UserID    string     `json:"user_id"`
	UserName  string     `json:"user_name"`
	UserEmail string     `json:"user_email"`
	FamilyID  *string    `json:"family_id"`
	Family    *string    `json:"family_name"`
	Label     string     `json:"label"`
	CreatedAt time.Time  `json:"created_at"`
	ExpiresAt time.Time  `json:"expires_at"`
	RevokedAt *time.Time `json:"revoked_at"`
	// Status is "active", "expired" or "revoked".
	Status string `json:"status"`
}

// AdminListShareLinks lists every share link not yet purged, newest first.
// GET /api/admin/share-links
func (s *Server) AdminListShareLinks(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT l.id, l.user_id, u.name, u.email, u.family_id, f.name, l.label,
		       l.created_at, l.expires_at, l.revoked_at,
		       CASE WHEN l.revoked_at IS NOT NULL THEN 'revoked'
		            WHEN l.expires_at <= now() THEN 'expired' ELSE 'active' END
		FROM share_links l
		JOIN users u ON u.id = l.user_id
		LEFT JOIN families f ON f.id = u.family_id
		ORDER BY l.created_at DESC
		LIMIT 500`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list share links")
		return
	}
	defer rows.Close()
	out := []adminShareLinkOut{}
	for rows.Next() {
		var l adminShareLinkOut
		if err := rows.Scan(&l.ID, &l.UserID, &l.UserName, &l.UserEmail, &l.FamilyID, &l.Family, &l.Label,
			&l.CreatedAt, &l.ExpiresAt, &l.RevokedAt, &l.Status); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read share links")
			return
		}
		out = append(out, l)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read share links")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminRevokeShareLink stops an active link at once.
// DELETE /api/admin/share-links/{id}
func (s *Server) AdminRevokeShareLink(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	var owner string
	err := s.Pool.QueryRow(r.Context(), `
		UPDATE share_links SET revoked_at = now()
		WHERE id = $1 AND revoked_at IS NULL AND expires_at > now()
		RETURNING user_id::text`, id).Scan(&owner)
	if err != nil {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	familyID, _ := s.familyIDForUser(r.Context(), owner)
	s.logAudit(r.Context(), claims.UserID, familyID, "admin.sharelink.revoke",
		"revoked share link "+id+" of user "+owner, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// AdminRevokeInvite deletes an invite code of any family or circle.
// DELETE /api/admin/invites/{id}
func (s *Server) AdminRevokeInvite(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "invite not found")
		return
	}
	var familyID *string
	var circleID *string
	err := s.Pool.QueryRow(r.Context(), `
		DELETE FROM invite_codes WHERE id = $1
		RETURNING family_id::text, circle_id::text`, id).Scan(&familyID, &circleID)
	if err != nil {
		writeError(w, http.StatusNotFound, "invite not found")
		return
	}
	fid := ""
	if familyID != nil {
		fid = *familyID
	} else if circleID != nil {
		fid = *circleID
	}
	s.logAudit(r.Context(), claims.UserID, fid, "admin.invite.revoke", "revoked invite "+id, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type adminCircleOut struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Icon        *string    `json:"icon"`
	CreatedBy   *string    `json:"created_by"`
	CreatorName *string    `json:"creator_name"`
	CreatedAt   time.Time  `json:"created_at"`
	ExpiresAt   *time.Time `json:"expires_at"`
	EndedAt     *time.Time `json:"ended_at"`
	Members     int        `json:"member_count"`
	// FamilyBacked circles mirror a family and cannot be ended.
	FamilyBacked bool `json:"family_backed"`
	// Status is "permanent", "active", "expired" or "ended".
	Status string `json:"status"`
}

// AdminListCircles lists every circle with member count and lifetime state.
// GET /api/admin/circles
func (s *Server) AdminListCircles(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT c.id, c.name, c.icon, c.created_by, u.name, c.created_at, c.expires_at, c.ended_at,
		       (SELECT count(*) FROM circle_members m WHERE m.circle_id = c.id),
		       EXISTS (SELECT 1 FROM families f WHERE f.id = c.id),
		       CASE WHEN c.ended_at IS NOT NULL THEN 'ended'
		            WHEN c.expires_at IS NULL THEN 'permanent'
		            WHEN c.expires_at <= now() THEN 'expired' ELSE 'active' END
		FROM circles c LEFT JOIN users u ON u.id = c.created_by
		ORDER BY (c.expires_at IS NULL), c.expires_at DESC, c.created_at DESC
		LIMIT 1000`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list circles")
		return
	}
	defer rows.Close()
	out := []adminCircleOut{}
	for rows.Next() {
		var c adminCircleOut
		if err := rows.Scan(&c.ID, &c.Name, &c.Icon, &c.CreatedBy, &c.CreatorName, &c.CreatedAt, &c.ExpiresAt,
			&c.EndedAt, &c.Members, &c.FamilyBacked, &c.Status); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read circles")
			return
		}
		out = append(out, c)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read circles")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminUpdateCircle ends a temporary circle early ({"end":true}) or extends it
// ({"extend_hours":1..720}, counted from the later of now and the current
// expiry). A circle ended early cannot be revived.
// PATCH /api/admin/circles/{id}
func (s *Server) AdminUpdateCircle(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "circle not found")
		return
	}
	var req struct {
		End         bool `json:"end"`
		ExtendHours *int `json:"extend_hours"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.End == (req.ExtendHours != nil) {
		writeError(w, http.StatusBadRequest, "send either end or extend_hours")
		return
	}
	if req.ExtendHours != nil && (*req.ExtendHours < 1 || *req.ExtendHours > int(maxTempCircle/time.Hour)) {
		writeError(w, http.StatusBadRequest, "extend_hours must be between 1 and 720")
		return
	}
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var expires, ended *time.Time
	var familyBacked bool
	if err := tx.QueryRow(r.Context(), `
		SELECT c.expires_at, c.ended_at, EXISTS (SELECT 1 FROM families f WHERE f.id = c.id)
		FROM circles c WHERE c.id = $1 FOR UPDATE`, id).Scan(&expires, &ended, &familyBacked); err != nil {
		writeError(w, http.StatusNotFound, "circle not found")
		return
	}
	if expires == nil || familyBacked {
		writeError(w, http.StatusConflict, "only a temporary circle can be extended or ended")
		return
	}
	if ended != nil {
		writeError(w, http.StatusConflict, "circle has already ended")
		return
	}
	now := time.Now()
	action := "admin.circle.end"
	if req.End {
		if !expires.After(now) {
			writeError(w, http.StatusConflict, "circle has already expired")
			return
		}
		if _, err := tx.Exec(r.Context(), `UPDATE circles SET ended_at = now() WHERE id = $1`, id); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to end circle")
			return
		}
	} else {
		base := *expires
		if base.Before(now) {
			base = now
		}
		target := base.Add(time.Duration(*req.ExtendHours) * time.Hour)
		// Same bound as the member endpoint: at most 30 days from now.
		if target.After(now.Add(maxTempCircle + time.Minute)) {
			writeError(w, http.StatusBadRequest, "expiry must be at most 30 days from now")
			return
		}
		if _, err := tx.Exec(r.Context(), `UPDATE circles SET expires_at = $1 WHERE id = $2`, target.UTC(), id); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to extend circle")
			return
		}
		action = "admin.circle.extend"
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if s.hub != nil {
		if req.End {
			s.hub.unsubscribeCircle(id)
		} else {
			s.resubscribeCircle(r.Context(), id)
		}
	}
	s.auditCircle(r.Context(), claims.UserID, id, action, "changed circle lifetime", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
