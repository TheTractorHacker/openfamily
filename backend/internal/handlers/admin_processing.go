package handlers

import (
	"net/http"
	"time"
)

type procMember struct {
	UserID        string     `json:"user_id"`
	Name          string     `json:"name"`
	Lane          string     `json:"lane"` // server | phone | not_chosen
	LastDataAt    *time.Time `json:"last_data_at"`
	PointsToday   int        `json:"points_today"`
	LastPrivateAt *time.Time `json:"last_private_update_at"`
}

type procCircle struct {
	ID      string       `json:"id"`
	Name    string       `json:"name"`
	Assist  bool         `json:"server_assist"`
	Members []procMember `json:"members"`
}

// AdminProcessingOverview is GET /api/admin/processing-overview (platform
// admin): the server key state and, per Private circle with server assist,
// which members use the server, which keep data on the phone and which have
// not chosen, plus when data last arrived. Metadata only: timestamps and
// counts, never coordinates.
func (s *Server) AdminProcessingOverview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	key := map[string]any{"state": "none"}
	if dev, err := s.pinnedServerDevice(ctx); err == nil && dev != nil {
		key = map[string]any{"state": "approved", "device": dev.Short, "label": dev.Label}
	} else {
		var n int
		if s.Pool.QueryRow(ctx, `SELECT count(*) FROM device_keys WHERE kind = 'server' AND revoked_at IS NULL`).Scan(&n) == nil && n > 0 {
			key = map[string]any{"state": "waiting"}
		}
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT c.id::text, c.name, c.server_assist, u.id::text, u.name,
		       COALESCE(p.lane, 'not_chosen'),
		       GREATEST(mp.ts, (SELECT max(d.last_seen) FROM devices d WHERE d.user_id = u.id)),
		       (SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id
		         WHERE d.user_id = u.id AND l.ts >= date_trunc('day', now())),
		       (SELECT max(i.received_at) FROM e2ee_items i JOIN device_keys k ON k.device_id = i.device_id
		         WHERE k.user_id = u.id AND i.circle_id = c.id)
		FROM circles c
		JOIN live_circle_members m ON m.circle_id = c.id
		JOIN users u ON u.id = m.user_id
		LEFT JOIN e2ee_processing_pref p ON p.circle_id = c.id AND p.user_id = u.id
		LEFT JOIN member_positions mp ON mp.user_id = u.id
		WHERE c.e2ee_mode = 'private' AND c.server_assist
		ORDER BY c.name, u.name
		LIMIT 2000`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load processing overview")
		return
	}
	defer rows.Close()
	out := []procCircle{}
	idx := map[string]int{}
	for rows.Next() {
		var cid, cname string
		var assist bool
		var m procMember
		if err := rows.Scan(&cid, &cname, &assist, &m.UserID, &m.Name, &m.Lane, &m.LastDataAt, &m.PointsToday, &m.LastPrivateAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read processing overview")
			return
		}
		i, ok := idx[cid]
		if !ok {
			out = append(out, procCircle{ID: cid, Name: cname, Assist: assist, Members: []procMember{}})
			i = len(out) - 1
			idx[cid] = i
		}
		out[i].Members = append(out[i].Members, m)
	}
	writeJSON(w, http.StatusOK, map[string]any{"server_key": key, "circles": out, "server_time": time.Now().UTC()})
}
