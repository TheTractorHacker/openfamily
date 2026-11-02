package handlers

import (
	"net/http"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

type adminBubbleMember struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

type adminBubbleJSON struct {
	ID            string              `json:"id"`
	CircleID      string              `json:"circle_id"`
	CircleName    string              `json:"circle_name"`
	CreatorID     string              `json:"creator_id"`
	CreatorName   string              `json:"creator_name"`
	SubjectID     string              `json:"subject_id"`
	SubjectName   string              `json:"subject_name"`
	RadiusM       int                 `json:"radius_m"`
	NotifyReenter bool                `json:"notify_reenter"`
	Inside        bool                `json:"inside"`
	CreatedAt     time.Time           `json:"created_at"`
	ExpiresAt     time.Time           `json:"expires_at"`
	Members       []adminBubbleMember `json:"members"`
}

// AdminListBubbles lists active (unexpired) bubbles across every family with
// the circle's members. Read-only; coordinates are deliberately not included.
// GET /api/admin/bubbles
func (s *Server) AdminListBubbles(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT b.id::text, b.circle_id::text, c.name, b.creator_id::text, cu.name, b.subject_id::text, su.name,
		       b.radius_m, b.notify_reenter, b.last_inside, b.created_at, b.expires_at,
		       COALESCE((SELECT json_agg(json_build_object('id', m.user_id::text, 'name', mu.name, 'role', m.role)
		                                 ORDER BY mu.name)
		                 FROM circle_members m JOIN users mu ON mu.id = m.user_id
		                 WHERE m.circle_id = b.circle_id), '[]'::json)
		FROM bubbles b
		JOIN circles c ON c.id = b.circle_id
		JOIN users cu ON cu.id = b.creator_id
		JOIN users su ON su.id = b.subject_id
		WHERE b.expires_at > now()
		ORDER BY b.expires_at, b.id
		LIMIT 500`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load bubbles")
		return
	}
	defer rows.Close()
	out := []adminBubbleJSON{}
	for rows.Next() {
		var b adminBubbleJSON
		if err := rows.Scan(&b.ID, &b.CircleID, &b.CircleName, &b.CreatorID, &b.CreatorName, &b.SubjectID, &b.SubjectName,
			&b.RadiusM, &b.NotifyReenter, &b.Inside, &b.CreatedAt, &b.ExpiresAt, &b.Members); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read bubbles")
			return
		}
		out = append(out, b)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read bubbles")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"bubbles": out})
}
