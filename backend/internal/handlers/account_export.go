package handlers

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/wheresfrank/openfamily/backend/internal/middleware"
)

const (
	exportPerUser    = 2
	exportWindow     = time.Hour
	exportMaxPoints  = 2_000_000
	exportFlushEvery = 2000
)

// ExportMe streams the caller's own data as one JSON document: profile,
// devices (no push tokens or ingest keys), places they created, and every
// stored location point of their devices (the database's retention policy
// already bounds history). The document ends with "complete":true; a client
// that does not see it must treat the download as truncated, since a failure
// mid-stream cannot change the already-sent 200 status.
func (s *Server) ExportMe(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !s.allowKey(w, "export:user:"+claims.UserID, exportPerUser, exportWindow) {
		return
	}
	ctx := r.Context()
	user, err := s.userProfileByID(r, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load profile")
		return
	}

	type deviceOut struct {
		ID         string     `json:"id"`
		Platform   string     `json:"platform"`
		Name       *string    `json:"name"`
		AppVersion *string    `json:"app_version"`
		LastSeen   *time.Time `json:"last_seen"`
		CreatedAt  time.Time  `json:"created_at"`
	}
	devices := []deviceOut{}
	drows, err := s.Pool.Query(ctx, `
		SELECT id, platform, name, app_version, last_seen, created_at
		FROM devices WHERE user_id = $1 ORDER BY created_at`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load devices")
		return
	}
	for drows.Next() {
		var d deviceOut
		if err := drows.Scan(&d.ID, &d.Platform, &d.Name, &d.AppVersion, &d.LastSeen, &d.CreatedAt); err != nil {
			drows.Close()
			writeError(w, http.StatusInternalServerError, "failed to load devices")
			return
		}
		devices = append(devices, d)
	}
	drows.Close()

	type placeOut struct {
		ID           string    `json:"id"`
		FamilyID     string    `json:"family_id"`
		Name         string    `json:"name"`
		Type         string    `json:"type"`
		Address      string    `json:"address"`
		Lat          *float64  `json:"lat"`
		Lon          *float64  `json:"lon"`
		RadiusMeters *float64  `json:"radius_meters"`
		CreatedAt    time.Time `json:"created_at"`
	}
	places := []placeOut{}
	prows, err := s.Pool.Query(ctx, `
		SELECT id, family_id, name, type, address, ST_Y(geom), ST_X(geom), radius_meters, created_at
		FROM places WHERE created_by = $1 ORDER BY created_at`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load places")
		return
	}
	for prows.Next() {
		var p placeOut
		if err := prows.Scan(&p.ID, &p.FamilyID, &p.Name, &p.Type, &p.Address, &p.Lat, &p.Lon, &p.RadiusMeters, &p.CreatedAt); err != nil {
			prows.Close()
			writeError(w, http.StatusInternalServerError, "failed to load places")
			return
		}
		places = append(places, p)
	}
	prows.Close()

	lrows, err := s.Pool.Query(ctx, `
		SELECT l.device_id, l.ts, ST_Y(l.geom), ST_X(l.geom), l.accuracy_meters, l.altitude_meters,
		       l.speed_mps, l.heading_deg, l.battery_pct, l.motion_state, l.source
		FROM locations l JOIN devices d ON d.id = l.device_id
		WHERE d.user_id = $1
		ORDER BY l.ts
		LIMIT $2`, claims.UserID, exportMaxPoints)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load locations")
		return
	}
	defer lrows.Close()

	s.logAudit(ctx, claims.UserID, "", "account.export_started", "started data export", clientIP(r))
	now := time.Now().UTC()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="openfamily-export-%s.json"`, now.Format("20060102")))
	w.WriteHeader(http.StatusOK)

	bw := bufio.NewWriterSize(w, 32<<10)
	flusher, _ := w.(http.Flusher)
	mustJSON := func(v any) []byte { b, _ := json.Marshal(v); return b }

	bw.WriteString(`{"exported_at":`)
	bw.Write(mustJSON(now))
	bw.WriteString(`,"profile":`)
	bw.Write(mustJSON(user))
	bw.WriteString(`,"devices":`)
	bw.Write(mustJSON(devices))
	bw.WriteString(`,"places_created":`)
	bw.Write(mustJSON(places))
	bw.WriteString(`,"locations":[`)

	type pointOut struct {
		DeviceID  string    `json:"device_id"`
		TS        time.Time `json:"ts"`
		Lat       float64   `json:"lat"`
		Lon       float64   `json:"lon"`
		Accuracy  *float64  `json:"accuracy_meters"`
		Altitude  *float64  `json:"altitude_meters"`
		Speed     *float64  `json:"speed_mps"`
		Heading   *float64  `json:"heading_deg"`
		Battery   *float64  `json:"battery_pct"`
		Motion    *string   `json:"motion_state"`
		SourceTag *string   `json:"source"`
	}
	n := 0
	for lrows.Next() {
		var p pointOut
		if err := lrows.Scan(&p.DeviceID, &p.TS, &p.Lat, &p.Lon, &p.Accuracy, &p.Altitude,
			&p.Speed, &p.Heading, &p.Battery, &p.Motion, &p.SourceTag); err != nil {
			return // no "complete" marker: the client sees a truncated document
		}
		if n > 0 {
			bw.WriteByte(',')
		}
		bw.Write(mustJSON(p))
		n++
		if n%exportFlushEvery == 0 {
			if bw.Flush() != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
	}
	if lrows.Err() != nil {
		return
	}
	fmt.Fprintf(bw, `],"location_count":%d,"complete":true}`, n)
	bw.WriteByte('\n')
	_ = bw.Flush()
	s.logAudit(ctx, claims.UserID, "", "account.export", fmt.Sprintf("exported own data (%d location points)", n), clientIP(r))
}
