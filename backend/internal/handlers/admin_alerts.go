package handlers

import (
	"net/http"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Platform-admin review of recent alerts (check-ins, help, SOS) and who was
// notified. Coordinates are never returned (only whether the alert carried a
// location), and neither is the free-text note or the share link: the page is
// for delivery review, not for reading someone's emergency.

type adminAlertDelivery struct {
	Recipient      string     `json:"recipient"`
	Channel        string     `json:"channel"`
	State          string     `json:"state"`
	Error          string     `json:"error,omitempty"`
	SentAt         *time.Time `json:"sent_at"`
	DeliveredAt    *time.Time `json:"delivered_at"`
	AcknowledgedAt *time.Time `json:"acknowledged_at"`
}

type adminAlertOut struct {
	ID          string               `json:"id"`
	Type        string               `json:"type"`
	Status      string               `json:"status"`
	SenderID    string               `json:"sender_id"`
	SenderName  string               `json:"sender_name"`
	FamilyName  string               `json:"family_name"`
	HasLocation bool                 `json:"has_location"`
	CreatedAt   time.Time            `json:"created_at"`
	ResolvedAt  *time.Time           `json:"resolved_at"`
	Deliveries  []adminAlertDelivery `json:"deliveries"`
}

// AdminListAlerts lists recent alerts newest first with per-recipient delivery
// and acknowledgement state. ?status=active|resolved, ?type=, ?limit=,
// ?before=<alert id> for the next page.
// GET /api/admin/alerts
func (s *Server) AdminListAlerts(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	q := r.URL.Query()
	status, typ := q.Get("status"), q.Get("type")
	if status != "" && status != "active" && status != "resolved" {
		writeError(w, http.StatusBadRequest, "invalid status")
		return
	}
	if len(typ) > 40 {
		writeError(w, http.StatusBadRequest, "invalid type")
		return
	}
	var before any
	if v := q.Get("before"); v != "" {
		if !circles.ValidID(v) {
			writeError(w, http.StatusBadRequest, "invalid before")
			return
		}
		before = v
	}
	limit := adminLimit(q)
	rows, err := s.Pool.Query(r.Context(), `
		SELECT a.id::text, a.type, a.status, a.user_id::text, u.name, COALESCE(f.name, ''),
		       (a.lat IS NOT NULL AND a.lon IS NOT NULL), a.created_at, a.resolved_at,
		       COALESCE((SELECT json_agg(json_build_object(
		                   'recipient', COALESCE(NULLIF(d.recipient_label, ''), ru.name, ''),
		                   'channel', d.channel, 'state', d.state, 'error', d.error,
		                   'sent_at', d.sent_at, 'delivered_at', d.delivered_at,
		                   'acknowledged_at', d.acknowledged_at) ORDER BY d.created_at, d.id)
		                 FROM alert_deliveries d LEFT JOIN users ru ON ru.id = d.recipient_user_id
		                 WHERE d.alert_id = a.id), '[]'::json)
		FROM alerts a
		JOIN users u ON u.id = a.user_id
		LEFT JOIN families f ON f.id = a.family_id
		WHERE ($1::text = '' OR a.status = $1)
		  AND ($2::text = '' OR a.type = $2)
		  AND ($3::uuid IS NULL OR (a.created_at, a.id) < (SELECT b.created_at, b.id FROM alerts b WHERE b.id = $3::uuid))
		ORDER BY a.created_at DESC, a.id DESC
		LIMIT $4`, status, typ, before, limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list alerts")
		return
	}
	defer rows.Close()
	out := []adminAlertOut{}
	for rows.Next() {
		var a adminAlertOut
		if err := rows.Scan(&a.ID, &a.Type, &a.Status, &a.SenderID, &a.SenderName, &a.FamilyName,
			&a.HasLocation, &a.CreatedAt, &a.ResolvedAt, &a.Deliveries); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read alerts")
			return
		}
		out = append(out, a)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read alerts")
		return
	}
	next := ""
	if len(out) > limit {
		out = out[:limit]
		next = out[limit-1].ID
	}
	writeJSON(w, http.StatusOK, map[string]any{"alerts": out, "next_before": next})
}
